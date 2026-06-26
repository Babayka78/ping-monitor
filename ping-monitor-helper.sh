#!/usr/bin/env bash
# ~/.ping-monitor/ping-monitor-helper.sh
# Restricted SSH helper script for pi_ping_monitor

# Restrict PATH to known-safe system locations to prevent environment injection.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Fail fast with a clear diagnostic if any required macOS tool is missing.
for _bin in ioreg networksetup awk grep cut tr openssl; do
    command -v "$_bin" > /dev/null 2>&1 || { echo "Error: Required binary not found: $_bin" >&2; exit 1; }
done
unset _bin

unsecret() {
    printf '%s' "$1" | openssl base64 -d -A | rev
}

# Safe key=value parser — reads HOTSPOT_SSID and HOTSPOT_PASSWORD without
# executing the config file as shell code.
HOTSPOT_SSID=""
HOTSPOT_PASSWORD=""
ENV_FILE="$HOME/.ping-monitor/config.env"
if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r _key _value; do
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"  
        [[ -z "$_key" || "$_key" == \#* ]] && continue
        _value="${_value%$'\r'}"
        if [[ ("$_value" == \"*\" || "$_value" == \'*\') && ${#_value} -ge 2 ]]; then
            _value="${_value:1:${#_value}-2}"
        fi
        case "$_key" in
            HOTSPOT_SSID)     HOTSPOT_SSID="$_value" ;;
            HOTSPOT_PASSWORD) HOTSPOT_PASSWORD="$_value" ;;
        esac
    done < <(grep '=' "$ENV_FILE")
    unset _key _value
    
    if [[ -n "$HOTSPOT_PASSWORD" ]]; then
        HOTSPOT_PASSWORD="$(unsecret "$HOTSPOT_PASSWORD")"
    fi
fi

# The SSH server places the requested command here when using Forced Commands.
# Trim leading/trailing whitespace for a reliable exact match.
CMD="${SSH_ORIGINAL_COMMAND:-}"
CMD="${CMD#"${CMD%%[![:space:]]*}"}"
CMD="${CMD%"${CMD##*[![:space:]]}"}"  

case "$CMD" in
    check_lid)
        # Returns Yes, No, or Unknown — normalized to a guaranteed single-word output.
        _lid_raw=$(ioreg -r -k AppleClamshellState -d 4 | grep AppleClamshellState | cut -d= -f2 | tr -d ' ')
        case "$_lid_raw" in
            Yes|No) printf '%s\n' "$_lid_raw" ;;
            *)      printf 'Unknown\n' ;;
        esac
        ;;
    switch_wifi)
        if [[ -z "${HOTSPOT_SSID:-}" || -z "${HOTSPOT_PASSWORD:-}" ]]; then
            echo "Error: HOTSPOT_SSID or HOTSPOT_PASSWORD is not configured on the Mac."
            exit 1
        fi
        WIFI_IF=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
        if [[ -z "$WIFI_IF" ]]; then
            echo "Error: Could not determine Wi-Fi interface."
            exit 1
        fi
        if ! networksetup -setairportnetwork "$WIFI_IF" "$HOTSPOT_SSID" "$HOTSPOT_PASSWORD"; then
            echo "Error: Failed to connect to hotspot '$HOTSPOT_SSID'"
            exit 1
        fi
        ;;
    *)
        echo "Access Denied: Command '$CMD' is not allowed."
        exit 1
        ;;
esac
