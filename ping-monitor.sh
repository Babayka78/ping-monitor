#!/usr/bin/env bash
# Note: 'set -e' is intentionally omitted because ping command failures are handled manually.
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ping-monitor/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "Run install.sh or create the config file manually." >&2
  exit 1
fi

# Safe key=value parser — does NOT execute the config file as shell code.
_load_config() {
  local _key _value
  while IFS='=' read -r _key _value; do
    _key="${_key#"${_key%%[![:space:]]*}"}"
    _key="${_key%"${_key##*[![:space:]]}"}"  
    [[ -z "$_key" || "$_key" == \#* ]] && continue
    _value="${_value%$'\r'}"
    if [[ ("$_value" == \"*\" || "$_value" == \'*\') && ${#_value} -ge 2 ]]; then
      _value="${_value:1:${#_value}-2}"
    fi
    case "$_key" in
      TARGET_MAIN|CROSS_CHECK|TARGET_MAC|HOTSPOT_SSID|HOTSPOT_PASSWORD|\
      AUTOMATE_HOST|AUTOMATE_PORT|AUTOMATE_ENDPOINT|SSH_USER|SSH_KEY_PATH|\
      MAIN_INTERVAL|SIDE_INTERVAL|DEBUG|PING_BIN|SSH_BIN|CURL_BIN)
        printf -v "$_key" '%s' "$_value"
        ;;
    esac
  done < <(grep '=' "$1")
}
_load_config "$CONFIG_FILE"

# Note: HOTSPOT_PASSWORD is intentionally omitted from this check as it is only used by the Mac helper.
_missing=()
for _var in TARGET_MAIN TARGET_MAC HOTSPOT_SSID \
            AUTOMATE_HOST AUTOMATE_PORT AUTOMATE_ENDPOINT SSH_USER SSH_KEY_PATH; do
  if [[ -z "${!_var:-}" ]]; then
    _missing+=("$_var")
  fi
done
if [[ ${#_missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required config variables: ${_missing[*]}" >&2
  exit 1
fi

MAIN_INTERVAL="${MAIN_INTERVAL:-5}"
SIDE_INTERVAL="${SIDE_INTERVAL:-30}"
DEBUG="${DEBUG:-false}"
PING_BIN="${PING_BIN:-$(command -v ping)}"
SSH_BIN="${SSH_BIN:-$(command -v ssh)}"
CURL_BIN="${CURL_BIN:-$(command -v curl)}"

[[ -n "$PING_BIN" ]] || { echo "ERROR: ping not found" >&2; exit 1; }
[[ -n "$SSH_BIN" ]]  || { echo "ERROR: ssh not found" >&2; exit 1; }
[[ -n "$CURL_BIN" ]] || { echo "ERROR: curl not found" >&2; exit 1; }
[[ -f "$SSH_KEY_PATH" ]] || { echo "ERROR: SSH key not found: $SSH_KEY_PATH" >&2; exit 1; }

# Validate numeric parameters and host fields to catch silent misconfigurations early.
_validate_integer() {
  local _name="$1" _val="$2"
  [[ "$_val" =~ ^[0-9]+$ ]] || { echo "ERROR: $_name must be a positive integer, got: '$_val'" >&2; exit 1; }
}
_validate_host() {
  local _name="$1" _val="$2"
  [[ -n "$_val" && "$_val" != *' '* ]] || { echo "ERROR: $_name must be a non-empty string without spaces, got: '$_val'" >&2; exit 1; }
}
_validate_integer MAIN_INTERVAL  "$MAIN_INTERVAL"
_validate_integer SIDE_INTERVAL  "$SIDE_INTERVAL"
_validate_integer AUTOMATE_PORT  "$AUTOMATE_PORT"
_validate_host    TARGET_MAIN    "$TARGET_MAIN"
[[ -z "$CROSS_CHECK" ]] || _validate_host CROSS_CHECK "$CROSS_CHECK"
_validate_host    TARGET_MAC     "$TARGET_MAC"
_validate_host    AUTOMATE_HOST  "$AUTOMATE_HOST"

LOG_DIR="/var/log/ping-monitor"
LOG_FILE="$LOG_DIR/outages.log"
DEBUG_LOG="$LOG_DIR/debug.log"
STATE_DIR="/var/lib/ping-monitor"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
SSH_COMMON_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -i "$SSH_KEY_PATH")

# Create dirs and files only if they don't exist; avoid resetting intentional permission changes.
[[ -d "$LOG_DIR" ]]   || { mkdir -p "$LOG_DIR"   && chmod 755 "$LOG_DIR"; }
[[ -d "$STATE_DIR" ]] || { mkdir -p "$STATE_DIR" && chmod 755 "$STATE_DIR"; }
[[ -f "$LOG_FILE" ]]  || { touch "$LOG_FILE"  && chmod 644 "$LOG_FILE"; }
[[ -f "$DEBUG_LOG" ]] || { touch "$DEBUG_LOG" && chmod 644 "$DEBUG_LOG"; }

# Ensure only one instance runs at a time.
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "ERROR: Another instance of ping-monitor is already running." >&2; exit 1; }

echo "$(date '+%Y-%m-%d %H:%M:%S') - ping-monitor started" >> "$LOG_FILE"

debug_log() {
  [[ "${DEBUG,,}" =~ ^(true|1|yes)$ ]] || return 0
  
  # Ensure log directory exists in case it was deleted while running
  [[ -d "$LOG_DIR" ]] || { mkdir -p "$LOG_DIR" && chmod 755 "$LOG_DIR"; }

  # Rotate debug log when it exceeds 50 MB.
  # stat -c and truncate are GNU coreutils — available on Raspberry Pi OS.
  if (( $(stat -c%s "$DEBUG_LOG" 2>/dev/null || echo 0) > 52428800 )); then
    truncate -s 0 "$DEBUG_LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: [debug.log rotated — exceeded 50 MB]" >> "$DEBUG_LOG"
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') - DEBUG: $1" >> "$DEBUG_LOG"
}

main_state="up"
main_outage_start=""
side_state="up"

if [[ -f "$STATE_FILE" ]]; then
  # Safe parser — reads only the three known state variables without executing the file.
  while IFS='=' read -r _state_key _state_val; do
    _state_key="${_state_key#"${_state_key%%[![:space:]]*}"}"
    _state_key="${_state_key%"${_state_key##*[![:space:]]}"}"  
    [[ -z "$_state_key" || "$_state_key" == \#* ]] && continue
    _state_val="${_state_val%$'\r'}"
    if [[ ("$_state_val" == \"*\" || "$_state_val" == \'*\') && ${#_state_val} -ge 2 ]]; then
      _state_val="${_state_val:1:${#_state_val}-2}"
    fi
    case "$_state_key" in
      main_state|main_outage_start|side_state)
        printf -v "$_state_key" '%s' "$_state_val"
        ;;
    esac
  done < <(grep '=' "$STATE_FILE")
  unset _state_key _state_val
  main_state="${main_state:-up}"
  main_outage_start="${main_outage_start:-}"
  side_state="${side_state:-up}"
fi

# Saves variables to a temporary file, then overwrites the state file atomically.
save_state() {
  local tmp
  [[ -d "$STATE_DIR" ]] || { mkdir -p "$STATE_DIR" && chmod 755 "$STATE_DIR"; }
  tmp="$(mktemp)"
  cat > "$tmp" <<STATE
main_state="$main_state"
main_outage_start="$main_outage_start"
side_state="$side_state"
STATE
  mv "$tmp" "$STATE_FILE"
}

# Graceful shutdown: save state before exiting on SIGTERM / SIGINT / SIGHUP.
_cleanup() {
  debug_log "Signal received — saving state and exiting."
  save_state
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ping-monitor stopped" >> "$LOG_FILE"
  exit 0
}
trap _cleanup SIGTERM SIGINT SIGHUP

# Records an outage event (start and end times) to the main outage log.
# Note: date -d is GNU coreutils-specific (available on Raspberry Pi OS / Debian).
write_log() {
  local end_ts_hms start_ts_compact
  [[ -d "$LOG_DIR" ]] || { mkdir -p "$LOG_DIR" && chmod 755 "$LOG_DIR"; }
  
  end_ts_hms=$(date '+%H:%M:%S')
  start_ts_compact=$(date -d "$main_outage_start" '+%d%m%y %H:%M:%S' 2>/dev/null || printf '%s' "$main_outage_start")
  if [[ "$side_state" == "down" ]]; then
    printf '%s - %s %s\n' "$start_ts_compact" "$end_ts_hms" "$CROSS_CHECK" >> "$LOG_FILE"
  else
    printf '%s - %s\n' "$start_ts_compact" "$end_ts_hms" >> "$LOG_FILE"
  fi
}

# Queries the Mac over SSH to check if the lid is closed (returns Yes/No).
check_mac_lid() {
  # Hard wall-clock timeout in addition to SSH ConnectTimeout/ServerAlive options,
  # to guard against non-network hangs that SSH options cannot catch.
  timeout 15 "$SSH_BIN" "${SSH_COMMON_OPTS[@]}" "$SSH_USER@$TARGET_MAC" "check_lid"
}

# Sends an HTTP POST request to the Automate app on the Android phone.
trigger_phone_failover() {
  "$CURL_BIN" -s -S -w "\nHTTP_CODE:%{http_code}" -X POST -m 5 \
    "http://${AUTOMATE_HOST}:${AUTOMATE_PORT}/${AUTOMATE_ENDPOINT}" 2>&1
}

# Connects the Mac to the Android phone's Wi-Fi hotspot over SSH.
# This uses the restricted SSH helper script on the Mac side.
switch_mac_to_hotspot() {
  "$SSH_BIN" "${SSH_COMMON_OPTS[@]}" "$SSH_USER@$TARGET_MAC" "switch_wifi" 2>&1
}

while true; do
  if "$PING_BIN" -c 1 -W 1 "$TARGET_MAIN" >/dev/null 2>&1; then
    if [[ "$main_state" != "up" ]]; then
      # The first ping already succeeded (triggered this block); count it.
      # Require 2 more consecutive successes for a total of 3/3 confirmations.
      _ok=1
      for _c in 2 3; do
        sleep 2
        if "$PING_BIN" -c 1 -W 1 "$TARGET_MAIN" >/dev/null 2>&1; then
          _ok=$(( _ok + 1 ))
          debug_log "Main link ($TARGET_MAIN) confirmation ping $_c/3 OK."
        else
          debug_log "Main link ($TARGET_MAIN) confirmation ping $_c/3 FAILED — still down."
          _ok=0
          break
        fi
      done

      if [[ "$_ok" -ge 3 ]]; then
        debug_log "Main link ($TARGET_MAIN) confirmed UP after 3/3 pings."
        main_state="up"
        if [[ -n "$main_outage_start" ]]; then
          write_log
        fi
        main_outage_start=""
        side_state="up"
        save_state
      fi
    fi
    sleep "$MAIN_INTERVAL"
    continue
  fi

  if [[ "$main_state" != "down" ]]; then
    main_state="down"
    main_outage_start=$(date '+%Y-%m-%d %H:%M:%S')

    debug_log "Main link ($TARGET_MAIN) went down."
    side_state="down"
    if [[ -n "$CROSS_CHECK" ]]; then
      debug_log "Checking side link ($CROSS_CHECK) (3 attempts)..."
      for _attempt in 1 2 3; do
        if "$PING_BIN" -c 1 -W 1 "$CROSS_CHECK" >/dev/null 2>&1; then
          side_state="up"
          debug_log "Side link ($CROSS_CHECK) is UP (attempt $_attempt)."
          break
        fi
        debug_log "Side link ($CROSS_CHECK) did not respond (attempt $_attempt)."
        [[ $_attempt -lt 3 ]] && sleep 2
      done
      if [[ "$side_state" == "down" ]]; then
        debug_log "Side link ($CROSS_CHECK) is DOWN after 3 attempts."
      fi
    else
      side_state="up"
      debug_log "Side link check skipped (CROSS_CHECK is empty)."
    fi
    save_state

    debug_log "Triggering Automate failover (max 5s)..."
    CURL_OUT="$(trigger_phone_failover)"
    CURL_EXIT=$?
    HTTP_CODE="$(grep -o 'HTTP_CODE:[0-9]*' <<< "$CURL_OUT" | cut -d: -f2)"
    debug_log "Automate trigger finished. Exit code: $CURL_EXIT, HTTP: ${HTTP_CODE:-unknown}"
    if [[ "$CURL_EXIT" -ne 0 ]]; then
      debug_log "Note: A timeout/error from Automate is an expected feature, as the phone cuts Wi-Fi instantly."
    fi

    if "$PING_BIN" -c 1 -W 1 "$TARGET_MAC" >/dev/null 2>&1; then
      debug_log "Mac ($TARGET_MAC) is pingable. Checking lid state..."
      LID_STATE="$(check_mac_lid)"
      debug_log "Mac lid state: '$LID_STATE'"

      if [[ "$LID_STATE" == "No" ]]; then
        debug_log "Lid is open. Sleeping for 8 seconds before switching Mac Wi-Fi..."
        sleep 8

        debug_log "Switching Mac Wi-Fi to hotspot in background..."
        (
          for i in 1 2 3 4 5 6; do
            MAC_OUT="$(switch_mac_to_hotspot)"
            MAC_EXIT=$?
            if [[ "$MAC_OUT" == *"Could not find network"* ]]; then
              debug_log "Mac didn't find network yet (attempt $i/6). Retrying in 2s..."
              sleep 2
            else
              debug_log "Mac switch finished (attempt $i/6). Exit code: $MAC_EXIT, Output: $MAC_OUT"
              break
            fi
          done
        ) &
      else
        debug_log "Lid is closed. Skipping Mac Wi-Fi switch."
      fi
    else
      debug_log "Mac ($TARGET_MAC) is NOT pingable. Skipping Mac Wi-Fi switch."
    fi
  fi

  sleep "$SIDE_INTERVAL"
done
