#!/usr/bin/env bash
set -uo pipefail

CONFIG_FILE="${CONFIG_FILE:-/etc/ping-monitor/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "Run install.sh or create the config file manually." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

_missing=()
for _var in TARGET_MAIN TARGET_SIDE TARGET_MAC HOTSPOT_SSID \
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

LOG_DIR="/var/log/ping-monitor"
LOG_FILE="$LOG_DIR/outages.log"
DEBUG_LOG="$LOG_DIR/debug.log"
STATE_DIR="/var/lib/ping-monitor"
STATE_FILE="$STATE_DIR/state"
LOCK_FILE="$STATE_DIR/lock"
SSH_COMMON_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH")

# Create dirs and files only if they don't exist; avoid resetting intentional permission changes.
[[ -d "$LOG_DIR" ]]   || { mkdir -p "$LOG_DIR"   && chmod 755 "$LOG_DIR"; }
[[ -d "$STATE_DIR" ]] || { mkdir -p "$STATE_DIR" && chmod 755 "$STATE_DIR"; }
[[ -f "$LOG_FILE" ]]  || { touch "$LOG_FILE"  && chmod 644 "$LOG_FILE"; }
[[ -f "$DEBUG_LOG" ]] || { touch "$DEBUG_LOG" && chmod 644 "$DEBUG_LOG"; }

# Ensure only one instance runs at a time.
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "ERROR: Another instance of ping-monitor is already running." >&2; exit 1; }

debug_log() {
  [[ "$DEBUG" == "true" ]] || return 0
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
  # shellcheck disable=SC1090
  source "$STATE_FILE" || true
  main_state="${main_state:-up}"
  main_outage_start="${main_outage_start:-}"
  side_state="${side_state:-up}"
fi

# Saves variables to a temporary file, then overwrites the state file atomically.
save_state() {
  local tmp
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
  exit 0
}
trap _cleanup SIGTERM SIGINT SIGHUP

# Records an outage event (start and end times) to the main outage log.
# Note: date -d is GNU coreutils-specific (available on Raspberry Pi OS / Debian).
write_log() {
  local end_ts_hms start_ts_compact
  end_ts_hms=$(date '+%H:%M:%S')
  start_ts_compact=$(date -d "$main_outage_start" '+%d%m%y %H:%M:%S' 2>/dev/null || printf '%s' "$main_outage_start")
  if [[ "$side_state" == "down" ]]; then
    printf '%s - %s %s\n' "$start_ts_compact" "$end_ts_hms" "$TARGET_SIDE" >> "$LOG_FILE"
  else
    printf '%s - %s\n' "$start_ts_compact" "$end_ts_hms" >> "$LOG_FILE"
  fi
}

# Queries the Mac over SSH to check if the lid is closed (returns Yes/No).
check_mac_lid() {
  "$SSH_BIN" "${SSH_COMMON_OPTS[@]}" "$SSH_USER@$TARGET_MAC" "check_lid"
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
          ((_ok++)) || true
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

    debug_log "Main link ($TARGET_MAIN) went down. Checking side link ($TARGET_SIDE) (3 attempts)..."
    side_state="down"
    for _attempt in 1 2 3; do
      if "$PING_BIN" -c 1 -W 1 "$TARGET_SIDE" >/dev/null 2>&1; then
        side_state="up"
        debug_log "Side link ($TARGET_SIDE) is UP (attempt $_attempt)."
        break
      fi
      debug_log "Side link ($TARGET_SIDE) did not respond (attempt $_attempt)."
      [[ $_attempt -lt 3 ]] && sleep 2
    done
    if [[ "$side_state" == "down" ]]; then
      debug_log "Side link ($TARGET_SIDE) is DOWN after 3 attempts."
    fi
    save_state

    debug_log "Triggering Automate failover (max 5s)..."
    CURL_OUT="$(trigger_phone_failover)"
    CURL_EXIT=$?
    HTTP_CODE="$(grep -o 'HTTP_CODE:[0-9]*' <<< "$CURL_OUT" | cut -d: -f2)"
    debug_log "Automate trigger finished. Exit code: $CURL_EXIT, HTTP: ${HTTP_CODE:-unknown}"

    if "$PING_BIN" -c 1 -W 1 "$TARGET_MAC" >/dev/null 2>&1; then
      debug_log "Mac ($TARGET_MAC) is pingable. Checking lid state..."
      LID_STATE="$(check_mac_lid)"
      debug_log "Mac lid state: '$LID_STATE'"

      if [[ "$LID_STATE" == "No" ]]; then
        debug_log "Lid is open. Sleeping for 8 seconds before switching Mac Wi-Fi..."
        sleep 8

        debug_log "Switching Mac Wi-Fi to hotspot in background..."
        (
          MAC_OUT="$(switch_mac_to_hotspot)"
          MAC_EXIT=$?
          debug_log "Mac switch finished. Exit code: $MAC_EXIT, Output: $MAC_OUT"
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
