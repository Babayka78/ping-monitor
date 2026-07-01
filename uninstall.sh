#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Pi Ping Monitor - Uninstallation Script
# -----------------------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (use sudo)." >&2
        exit 1
    fi
}

log()  { echo "[INFO] $1"; }
warn() { echo "[WARN] $1" >&2; }
die()  { echo "[FATAL] $1" >&2; exit 1; }

main() {
    require_root

    echo "================================================="
    echo " Pi Ping Monitor — Uninstallation "
    echo "================================================="
    
    local confirm
    read -r -p "This will completely remove the monitor, its logs, and the Mac helper. Continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Uninstallation aborted."
        exit 0
    fi

    # 1. Stop ping-monitor.service
    local SERVICE_NAME="ping-monitor.service"
    log "Stopping $SERVICE_NAME..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    local CONFIG_FILE="/etc/ping-monitor/config.env"
    local TARGET_MAC=""
    local SSH_USER=""
    local SSH_KEY_PATH=""
    local WEB_PORT=""
    
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Loading config from $CONFIG_FILE..."
        while IFS='=' read -r key val; do
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            val="${val%$'\r'}"
            [[ -z "$key" || "$key" == \#* ]] && continue
            if [[ ("$val" == \"*\" || "$val" == \'*\') && ${#val} -ge 2 ]]; then
                val="${val:1:${#val}-2}"
            fi
            case "$key" in
                TARGET_MAC) TARGET_MAC="$val" ;;
                SSH_USER)   SSH_USER="$val" ;;
                SSH_KEY_PATH) SSH_KEY_PATH="$val" ;;
                WEB_PORT) WEB_PORT="$val" ;;
            esac
        done < <(grep '=' "$CONFIG_FILE")
    else
        warn "Config file $CONFIG_FILE not found."
    fi

    local REAL_USER
    REAL_USER="${SUDO_USER:-root}"

    # --- MAC CLEANUP PHASE ---
    if [[ -n "$TARGET_MAC" && -n "$SSH_USER" ]]; then
        log "Connecting to Mac ($TARGET_MAC) for cleanup..."
        echo "-------------------------------------------------------------"
        echo " 🔐 ATTENTION: The system will now prompt for the Mac password"
        echo "    for user '$SSH_USER'. Characters will be hidden."
        echo "-------------------------------------------------------------"
        
        local MAC_SCRIPT
        MAC_SCRIPT=$(cat << 'EOF'
set -e
HAS_AUTH_BAK=0
HAS_KH_BAK=0

PI_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')

# 1. authorized_keys
if [ -f ~/.ssh/authorized_keys ] && grep -q 'command=".*ping-monitor-helper\.sh"' ~/.ssh/authorized_keys; then
    cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak
    HAS_AUTH_BAK=1
    grep -v 'command=".*ping-monitor-helper\.sh"' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp || true
    mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    if grep -q 'command=".*ping-monitor-helper\.sh"' ~/.ssh/authorized_keys; then
        echo "ERROR_AUTHORIZED_KEYS"
        mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
        exit 1
    fi
fi

# 2. known_hosts
if [ -f ~/.ssh/known_hosts ] && [ -n "$PI_IP" ] && grep -q "$PI_IP" ~/.ssh/known_hosts; then
    cp ~/.ssh/known_hosts ~/.ssh/known_hosts.bak
    HAS_KH_BAK=1
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -R "$PI_IP" >/dev/null 2>&1 || true
    else
        grep -v "$PI_IP" ~/.ssh/known_hosts > ~/.ssh/known_hosts.tmp || true
        mv ~/.ssh/known_hosts.tmp ~/.ssh/known_hosts
        chmod 600 ~/.ssh/known_hosts
    fi
    if grep -q "$PI_IP" ~/.ssh/known_hosts; then
        echo "ERROR_KNOWN_HOSTS"
        [ "$HAS_AUTH_BAK" -eq 1 ] && mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
        [ "$HAS_KH_BAK" -eq 1 ] && mv ~/.ssh/known_hosts.bak ~/.ssh/known_hosts
        exit 1
    fi
fi

# 3. .ping-monitor
if [ ! -d ~/.ping-monitor ]; then
    echo "MISSING_PING_MONITOR"
    exit 0
fi

rm -rf ~/.ping-monitor
if [ -d ~/.ping-monitor ]; then
    echo "ERROR_RM_DIR"
    [ "$HAS_AUTH_BAK" -eq 1 ] && mv ~/.ssh/authorized_keys.bak ~/.ssh/authorized_keys
    [ "$HAS_KH_BAK" -eq 1 ] && mv ~/.ssh/known_hosts.bak ~/.ssh/known_hosts
    exit 1
fi

[ "$HAS_AUTH_BAK" -eq 1 ] && rm -f ~/.ssh/authorized_keys.bak 2>/dev/null || true
[ "$HAS_KH_BAK" -eq 1 ] && rm -f ~/.ssh/known_hosts.bak 2>/dev/null || true
echo "MAC_CLEANUP_SUCCESS"
EOF
)

        # Force password auth to bypass restricted key
        local mac_output
        set +e
        mac_output=$(sudo -u "$REAL_USER" ssh -o ConnectTimeout=5 -o PubkeyAuthentication=no "$SSH_USER@$TARGET_MAC" "bash -s" <<< "$MAC_SCRIPT" 2>&1)
        set -e

        if [[ "$mac_output" == *"MISSING_PING_MONITOR"* ]]; then
            log "Directory ~/.ping-monitor is missing on Mac. Removing Mac info from local config."
            sed -i '/^TARGET_MAC=/d; /^SSH_USER=/d; /^SSH_KEY_PATH=/d' "$CONFIG_FILE" 2>/dev/null || true
            TARGET_MAC=""
            SSH_USER=""
            SSH_KEY_PATH=""
        elif [[ "$mac_output" == *"MAC_CLEANUP_SUCCESS"* ]]; then
            log "Mac cleanup successful."
        else
            warn "Mac cleanup failed or aborted."
            echo "Mac Output: $mac_output"
            die "Uninstallation interrupted. Fix Mac connection or state and try again."
        fi
    fi

    # --- LINUX CLEANUP PHASE ---
    log "Removing Linux components..."
    
    # Clean Mac from Pi's known_hosts
    if [[ -n "$TARGET_MAC" ]]; then
        local kh_path
        kh_path="$(getent passwd "$REAL_USER" | cut -d: -f6)/.ssh/known_hosts"
        if [[ -f "$kh_path" ]]; then
            sudo -u "$REAL_USER" ssh-keygen -R "$TARGET_MAC" >/dev/null 2>&1 || true
        fi
    fi

    log "Disabling $SERVICE_NAME..."
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE_NAME"
    systemctl daemon-reload

    log "Removing local logs and scripts..."
    rm -rf /var/log/ping-monitor
    rm -rf /var/lib/ping-monitor
    rm -f /usr/local/bin/ping-monitor.sh

    local key_to_remove="${SSH_KEY_PATH:-$(getent passwd "$REAL_USER" | cut -d: -f6)/.ssh/id_ed25519_ping_monitor}"
    log "Removing project SSH keys ($key_to_remove)..."
    rm -f "$key_to_remove" "${key_to_remove}.pub"

    log "Removing Nginx configuration for ping-monitor (if any)..."
    rm -f /etc/nginx/sites-enabled/ping-monitor.conf
    rm -f /etc/nginx/sites-available/ping-monitor.conf
    rm -f /etc/nginx/conf.d/ping-monitor.conf

    if command -v nginx >/dev/null 2>&1; then
        if systemctl is-active --quiet nginx 2>/dev/null; then
            if nginx -t >/dev/null 2>&1; then
                systemctl try-restart nginx
            else
                warn "Nginx config test failed after removal. Skipping Nginx restart."
            fi
        fi

        local other_sites=0
        for conf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*; do
            [[ -e "$conf" ]] || continue
            local base_name="$(basename "$conf")"
            if [[ "$base_name" != "default" && "$base_name" != "default.conf" ]]; then
                other_sites=$((other_sites + 1))
            fi
        done

        if [[ "$other_sites" -eq 0 ]]; then
            local del_nginx
            echo "It appears ping-monitor was the only custom site configured in Nginx."
            read -r -p "Do you want to completely uninstall the 'nginx' package and its dependencies from the system? [y/N]: " del_nginx
            if [[ "$del_nginx" =~ ^[Yy]$ ]]; then
                log "Uninstalling Nginx..."
                apt-get purge -y nginx nginx-common
                apt-get autoremove -y
            fi
        fi
    fi

    log "Removing /etc/ping-monitor..."
    rm -rf /etc/ping-monitor

    echo "================================================="
    echo " ✅ Uninstallation Complete!"
    echo "================================================="
}

main "$@"
