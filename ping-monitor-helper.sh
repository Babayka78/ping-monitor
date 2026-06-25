#!/usr/bin/env bash
# ~/.ping-monitor/ping-monitor-helper.sh
# Restricted SSH helper script for pi_ping_monitor

# Read local config containing HOTSPOT_SSID and HOTSPOT_PASSWORD
ENV_FILE="$HOME/.ping-monitor/config.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# The SSH server places the requested command here when using Forced Commands
CMD="${SSH_ORIGINAL_COMMAND:-}"

case "$CMD" in
    check_lid)
        # Returns Yes or No
        ioreg -r -k AppleClamshellState -d 4 | grep AppleClamshellState | cut -d= -f2 | tr -d ' '
        ;;
    switch_wifi)
        if [[ -z "${HOTSPOT_SSID:-}" ]]; then
            echo "Error: HOTSPOT_SSID is not configured on the Mac."
            exit 1
        fi
        networksetup -setairportnetwork en0 "$HOTSPOT_SSID"
        ;;
    *)
        echo "Access Denied: Command '$CMD' is not allowed."
        exit 1
        ;;
esac
