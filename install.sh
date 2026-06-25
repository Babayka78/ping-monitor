#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/ping-monitor"
CONFIG_FILE="$CONFIG_DIR/config.env"
SERVICE_NAME="ping-monitor.service"
INSTALL_BIN="/usr/local/bin/ping-monitor.sh"
LOG_DIR="/var/log/ping-monitor"
STATE_DIR="/var/lib/ping-monitor"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available/ping-monitor.conf"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled/ping-monitor.conf"
NGINX_CONF_D="/etc/nginx/conf.d/ping-monitor.conf"

OS_FAMILY="unknown"
IS_REINSTALL="false"
REAL_USER="${SUDO_USER:-}"
REAL_HOME=""

TARGET_MAIN=""
TARGET_SIDE=""
TARGET_MAC=""
HOTSPOT_SSID=""
HOTSPOT_PASSWORD=""
AUTOMATE_HOST=""
AUTOMATE_PORT=""
AUTOMATE_ENDPOINT=""
SSH_USER=""
SSH_KEY_PATH=""
MAIN_INTERVAL="5"
SIDE_INTERVAL="30"
DEBUG="false"
WEB_PORT=""

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

random_suffix() {
    openssl rand -hex 3
}

die() {
    echo "[!] $*" >&2
    exit 1
}

log() {
    echo "[*] $*"
}

warn() {
    echo "[W] $*"
}

# Ensures the script is run with sudo/root privileges
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        die "Run as root: sudo bash install.sh"
    fi
}

# Checks if the system is Debian-based for package management
detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]; then
            OS_FAMILY="debian"
        fi
    fi
}

# Installs packages non-interactively via apt-get
apt_install() {
    local packages=("$@")
    [[ "$OS_FAMILY" == "debian" ]] || die "Automatic package installation is only supported on Debian-like systems."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${packages[@]}"
}

# Checks and installs required system utilities (curl, ping, ssh, etc.)
install_bootstrap_deps() {
    local missing_deps=()

    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v ping >/dev/null 2>&1 || missing_deps+=("iputils-ping")
    command -v ip >/dev/null 2>&1 && command -v ss >/dev/null 2>&1 || missing_deps+=("iproute2")
    { command -v ssh && command -v ssh-keygen && command -v ssh-copy-id; } >/dev/null 2>&1 || missing_deps+=("openssh-client")

    log "Checking installer prerequisites..."

    if ((${#missing_deps[@]} > 0)); then
        warn "Missing required packages: ${missing_deps[*]}"
        log "Installing missing packages..."
        apt_install "${missing_deps[@]}"
    else
        log "All installer prerequisites are present."
    fi
}

ensure_project_files() {
    [[ -f "$SCRIPT_DIR/ping-monitor.sh" ]] || die "Missing file: $SCRIPT_DIR/ping-monitor.sh"
    [[ -f "$SCRIPT_DIR/ping-monitor.service" ]] || die "Missing file: $SCRIPT_DIR/ping-monitor.service"
    [[ -f "$SCRIPT_DIR/ping-monitor.conf" ]] || die "Missing file: $SCRIPT_DIR/ping-monitor.conf"
}

# Finds the actual non-root user who ran sudo (used for SSH keys and permissions)
detect_real_user() {
    if [[ -n "$REAL_USER" ]] && id "$REAL_USER" >/dev/null 2>&1; then
        REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        return
    fi

    REAL_USER="$(logname 2>/dev/null || true)"
    if [[ -n "$REAL_USER" ]] && id "$REAL_USER" >/dev/null 2>&1; then
        REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
        return
    fi

    if id "pi" >/dev/null 2>&1; then
        warn "Could not determine the real non-root user. Falling back to 'pi'."
        REAL_USER="pi"
        REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    else
        die "Could not determine the real non-root user."
    fi
}

# Parses an environment file, cleans quotes/returns, and loads variables into memory
load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    while IFS='=' read -r raw_key raw_value; do
        local key value
        key="$(trim "$raw_key")"
        value="$(trim "${raw_value:-}")"

        [[ -z "$key" || "$key" == \#* ]] && continue
        value="${value%\r}"

        if [[ ("$value" == \"*\" || "$value" == \'*\' ) && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        fi

        case "$key" in
            TARGET_MAIN|TARGET_SIDE|TARGET_MAC|HOTSPOT_SSID|AUTOMATE_HOST|AUTOMATE_PORT|AUTOMATE_ENDPOINT|SSH_USER|SSH_KEY_PATH|MAIN_INTERVAL|SIDE_INTERVAL|DEBUG|WEB_PORT)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < <(grep '=' "$file")
}

# Tries to auto-detect the ISP router IP and sets default values for variables
detect_defaults() {
    local isp_gw=""

    log "Detecting ISP router via ip route..."
    isp_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)"
    [[ "$isp_gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || isp_gw=""

    TARGET_MAIN="${TARGET_MAIN:-${isp_gw:-192.168.100.1}}"
    TARGET_SIDE="${TARGET_SIDE:-192.168.100.79}"
    TARGET_MAC="${TARGET_MAC:-192.168.0.173}"
    SSH_USER="${SSH_USER:-$REAL_USER}"
    SSH_KEY_PATH="${SSH_KEY_PATH:-$REAL_HOME/.ssh/id_ed25519_ping_monitor}"
    HOTSPOT_SSID="${HOTSPOT_SSID:-YourHotspotSSID}"
    HOTSPOT_PASSWORD="${HOTSPOT_PASSWORD:-YourHotspotPass}"
    AUTOMATE_HOST="${AUTOMATE_HOST:-192.168.0.65}"
    AUTOMATE_PORT="${AUTOMATE_PORT:-7801}"
    AUTOMATE_ENDPOINT="${AUTOMATE_ENDPOINT:-failover_$(random_suffix)}"
    MAIN_INTERVAL="${MAIN_INTERVAL:-5}"
    SIDE_INTERVAL="${SIDE_INTERVAL:-30}"
    DEBUG="${DEBUG:-true}"
    WEB_PORT="${WEB_PORT:-}"
}

# Helper function to ask the user a question with a default fallback
prompt_value() {
    local label="$1"
    local current="$2"
    local input
    read -r -p "$label [$current]: " input
    printf '%s' "${input:-$current}"
}

# Guides the user through setting up all required IP addresses and credentials
prompt_config() {
    echo
    echo "--- Environment Configuration ---"
    echo "Press [Enter] to accept the suggested defaults."

    TARGET_MAIN="$(prompt_value 'ISP Router IP (TARGET_MAIN)' "$TARGET_MAIN")"
    TARGET_SIDE="$(prompt_value 'Secondary Device IP for Network Check (TARGET_SIDE)' "$TARGET_SIDE")"
    TARGET_MAC="$(prompt_value 'Mac Computer IP (TARGET_MAC)' "$TARGET_MAC")"
    SSH_USER="$(prompt_value 'Mac SSH Username (SSH_USER)' "$SSH_USER")"
    SSH_KEY_PATH="$(prompt_value 'SSH Key Path (SSH_KEY_PATH)' "$SSH_KEY_PATH")"
    HOTSPOT_SSID="$(prompt_value 'Phone Hotspot SSID (HOTSPOT_SSID)' "$HOTSPOT_SSID")"
    HOTSPOT_PASSWORD="$(prompt_value 'Phone Hotspot Password (HOTSPOT_PASSWORD)' "$HOTSPOT_PASSWORD")"
    AUTOMATE_HOST="$(prompt_value 'Android Phone IP (AUTOMATE_HOST)' "$AUTOMATE_HOST")"
    AUTOMATE_PORT="$(prompt_value 'Automate HTTP Port (AUTOMATE_PORT)' "$AUTOMATE_PORT")"
    AUTOMATE_ENDPOINT="$(prompt_value 'Automate Endpoint (AUTOMATE_ENDPOINT)' "$AUTOMATE_ENDPOINT")"
}

# Generates an SSH key if needed, gives copy instructions, and tests connection to the Mac
setup_ssh_key_for_mac() {
    local key_dir pubkey copy_now gen_key test_now
    local def_ans="Y"
    local prompt_str="[Y/n]"

    if [[ "$IS_REINSTALL" == "true" ]]; then
        def_ans="N"
        prompt_str="[y/N]"
    fi

    key_dir="$(dirname "$SSH_KEY_PATH")"
    install -d -m 700 -o "$REAL_USER" -g "$REAL_USER" "$key_dir"

    if [[ -f "$SSH_KEY_PATH" ]]; then
        log "Existing SSH private key found: $SSH_KEY_PATH"
    else
        read -r -p "Generate dedicated SSH key for Mac access at $SSH_KEY_PATH? $prompt_str: " gen_key
        gen_key="${gen_key:-$def_ans}"

        if [[ "$gen_key" =~ ^[Yy]$ ]]; then
            log "Generating SSH key..."
            ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "ping-monitor@$(hostname)"
            chown "$REAL_USER:$REAL_USER" "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub" "$key_dir"
            chmod 600 "$SSH_KEY_PATH"
            chmod 644 "$SSH_KEY_PATH.pub"
            chmod 700 "$key_dir"
        else
            warn "SSH key generation skipped. Make sure SSH_KEY_PATH points to a valid private key."
            return 0
        fi
    fi

    pubkey="${SSH_KEY_PATH}.pub"
    [[ -f "$pubkey" ]] || die "Missing public key: $pubkey"

    echo
    echo "Before copying the key to your Mac:"
    echo "  1. Enable Remote Login on the Mac"
    echo "  2. Ensure user '$SSH_USER' is allowed to log in via SSH"
    echo "  3. Ensure the Mac is reachable at $TARGET_MAC"
    echo

    if sudo -u "$REAL_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 \
         -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" true 2>/dev/null; then
        log "SSH key auth already works, skipping ssh-copy-id."
    else
        read -r -p "Copy SSH public key to Mac now using ssh-copy-id? $prompt_str: " copy_now
        copy_now="${copy_now:-$def_ans}"

        if [[ "$copy_now" =~ ^[Yy]$ ]]; then
            if sudo -u "$REAL_USER" ssh-copy-id -i "$pubkey" "$SSH_USER@$TARGET_MAC"; then
                log "SSH public key installed successfully on the Mac."
            else
                warn "ssh-copy-id failed. Run this manually after enabling Remote Login on the Mac:"
                echo "  sudo -u \"$REAL_USER\" ssh-copy-id -i \"$pubkey\" \"$SSH_USER@$TARGET_MAC\""
            fi
        else
            echo "Run this manually when ready:"
            echo "  sudo -u \"$REAL_USER\" ssh-copy-id -i \"$pubkey\" \"$SSH_USER@$TARGET_MAC\""
        fi
    fi

    read -r -p "Test SSH connectivity to the Mac now? [Y/n]: " test_now
    test_now="${test_now:-Y}"
    if [[ "$test_now" =~ ^[Yy]$ ]]; then
        if sudo -u "$REAL_USER" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" 'echo SSH_OK' >/dev/null 2>&1; then
            log "SSH test succeeded."
        else
            warn "SSH test failed. You can continue, but failover actions may not work until SSH access is fixed."
        fi
    fi
}

# Creates the helper environment on the Mac and restricts the SSH key
deploy_mac_helper() {
    log "Deploying restricted SSH helper to Mac..."
    
    local safe_pass="${HOTSPOT_PASSWORD//\'/\'\\\'\'}"
    local safe_ssid="${HOTSPOT_SSID//\'/\'\\\'\'}"
    local pubkey_content
    pubkey_content="$(cat "${SSH_KEY_PATH}.pub")"

    # Base SSH command
    local SSH_CMD="sudo -u \"$REAL_USER\" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
    local AUTH_OPTS="-o BatchMode=yes -i \"$SSH_KEY_PATH\""
    
    # Check if the key is restricted
    local check_output
    check_output=$(eval "$SSH_CMD $AUTH_OPTS \"$SSH_USER@$TARGET_MAC\" true 2>&1" || true)

    if [[ "$check_output" == *"Access Denied"* ]]; then
        log "SSH key is already restricted. We need your Mac password to bypass the restriction and update the files."
        AUTH_OPTS="-o PubkeyAuthentication=no"
    elif [[ -n "$check_output" ]] && [[ "$check_output" != *"Permanently added"* ]]; then
        warn "Failed to test SSH connection: $check_output"
        return 1
    fi

    # Build the massive deployment payload
    local deploy_payload
    deploy_payload="$(cat <<EOF
mkdir -p ~/.ping-monitor
cat > ~/.ping-monitor/config.env <<'ENV_EOF'
HOTSPOT_SSID='${safe_ssid}'
HOTSPOT_PASSWORD='${safe_pass}'
ENV_EOF
chmod 600 ~/.ping-monitor/config.env

cat > ~/.ping-monitor/ping-monitor-helper.sh <<'HELPER_EOF'
$(cat "$SCRIPT_DIR/ping-monitor-helper.sh")
HELPER_EOF
chmod +x ~/.ping-monitor/ping-monitor-helper.sh

KEY_CONTENT="${pubkey_content}"
RESTRICTION="command=\"/Users/$SSH_USER/.ping-monitor/ping-monitor-helper.sh\",no-pty,no-port-forwarding,no-x11-forwarding,no-agent-forwarding"
grep -v "\$KEY_CONTENT" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp || true
echo "\$RESTRICTION \$KEY_CONTENT" >> ~/.ssh/authorized_keys.tmp
mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "DEPLOY_SUCCESS"
EOF
)"

    # Execute the payload in a single SSH connection
    if eval "$SSH_CMD $AUTH_OPTS \"$SSH_USER@$TARGET_MAC\" 'bash -s'" <<< "$deploy_payload" | grep -q "DEPLOY_SUCCESS"; then
        log "Mac environment updated and SSH key restricted successfully."
    else
        warn "Failed to update Mac environment."
        return 1
    fi
}

# Saves the final configuration variables to the system config file
write_config() {
    log "Saving configuration to $CONFIG_FILE..."
    install -d -m 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF_CONF'
# Generated by install.sh
EOF_CONF
    for key in TARGET_MAIN TARGET_SIDE TARGET_MAC HOTSPOT_SSID AUTOMATE_HOST AUTOMATE_PORT AUTOMATE_ENDPOINT SSH_USER SSH_KEY_PATH MAIN_INTERVAL SIDE_INTERVAL DEBUG WEB_PORT; do
        printf "%s='%s'\n" "$key" "${!key//\'/\'\\\'\'}" >> "$CONFIG_FILE"
    done
    chmod 600 "$CONFIG_FILE"
}

# Copies the script to /usr/local/bin and enables the systemd background service
install_service() {
    log "Installing ping-monitor service..."
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
    fi
    install -m 755 "$SCRIPT_DIR/ping-monitor.sh" "$INSTALL_BIN"
    install -d -m 755 "$LOG_DIR" "$STATE_DIR"
    install -m 644 "$SCRIPT_DIR/ping-monitor.service" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
}

# Checks if a specific port is already taken by another process
is_tcp_port_in_use() {
    local port="$1"
    ss -H -tln | awk -v p=":$port" '{if ($4 ~ p "$") exit 0} END {exit 1}'
}

# Finds the first available port for the web dashboard (tries 80, then 8080+)
select_dashboard_port() {
    local port

    if [[ -n "$WEB_PORT" ]]; then
        printf '%s\n' "$WEB_PORT"
        return 0
    fi

    if ! is_tcp_port_in_use 80; then
        printf '%s\n' 80
        return 0
    fi

    for ((port=8080; port<=8099; port++)); do
        if ! is_tcp_port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done

    die "Could not find a free dashboard port in the 80/8080-8099 range."
}

# Installs Nginx, configures the dashboard site, and reloads the web server
setup_web_dashboard() {
    local ws_installed=""
    local setup_nginx="Y"
    local nginx_target local_ip chosen_port

    echo
    echo "--- Web Dashboard Setup ---"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        ws_installed="nginx"
    elif systemctl is-active --quiet apache2 2>/dev/null; then
        ws_installed="apache2"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        ws_installed="caddy"
    elif systemctl is-active --quiet lighttpd 2>/dev/null; then
        ws_installed="lighttpd"
    fi

    if [[ -n "$ws_installed" && "$ws_installed" != "nginx" ]]; then
        warn "Detected active web server: $ws_installed"
        read -r -p "Install Nginx alongside $ws_installed on a different port? [y/N]: " setup_nginx
        setup_nginx="${setup_nginx:-N}"
        if [[ ! "$setup_nginx" =~ ^[Yy]$ ]]; then
            echo "    Nginx setup is skipped to avoid modifying an existing web stack."
            echo "    Serve dashboard files from: $LOG_DIR/"
            WEB_PORT=""
            return 0
        fi
    fi

    if [[ "$ws_installed" == "nginx" ]]; then
        read -r -p "Nginx is already active. Add/update ping-monitor dashboard config? [Y/n]: " setup_nginx
        setup_nginx="${setup_nginx:-Y}"
    elif [[ -z "$ws_installed" ]]; then
        read -r -p "Install and configure Nginx for the dashboard? [Y/n]: " setup_nginx
        setup_nginx="${setup_nginx:-Y}"
    fi

    if [[ ! "$setup_nginx" =~ ^[Yy]$ ]]; then
        log "Skipping web server setup."
        WEB_PORT=""
        return 0
    fi

    if [[ "$ws_installed" != "nginx" ]]; then
        log "Installing Nginx..."
        # Prevent Nginx from starting automatically during installation
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod +x /usr/sbin/policy-rc.d
        
        apt_install nginx
        
        # Restore normal service startup policy
        rm -f /usr/sbin/policy-rc.d
        
        # Remove default config that tries to bind to port 80
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    local suggested_port is_our_port
    while true; do
        suggested_port="$(select_dashboard_port)"
        read -r -p "Dashboard port [$suggested_port]: " chosen_port
        chosen_port="${chosen_port:-$suggested_port}"
        
        is_our_port="false"
        if [[ -f "$NGINX_SITES_ENABLED" ]] && grep -q -E "listen( \[::\])?:$chosen_port\b" "$NGINX_SITES_ENABLED" 2>/dev/null; then
            is_our_port="true"
        elif [[ -f "$NGINX_CONF_D" ]] && grep -q -E "listen( \[::\])?:$chosen_port\b" "$NGINX_CONF_D" 2>/dev/null; then
            is_our_port="true"
        elif [[ "$chosen_port" == "$WEB_PORT" ]]; then
            is_our_port="true"
        fi

        if [[ "$is_our_port" == "true" ]]; then
            break
        fi

        if is_tcp_port_in_use "$chosen_port"; then
            echo "[!] Port $chosen_port is already in use by another service. Please pick a different port."
        else
            break
        fi
    done
    WEB_PORT="$chosen_port"

    if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
        nginx_target="$NGINX_SITES_AVAILABLE"
    else
        install -d /etc/nginx/conf.d
        nginx_target="$NGINX_CONF_D"
    fi

    [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "Invalid port: $WEB_PORT"

    log "Configuring Nginx on port $WEB_PORT..."
    sed \
        -e "s|@@WEB_PORT@@|$WEB_PORT|g" \
        -e "s|@@LOG_DIR@@|$LOG_DIR|g" \
        "$SCRIPT_DIR/ping-monitor.conf" > "$nginx_target"

    if [[ "$nginx_target" == "$NGINX_SITES_AVAILABLE" ]]; then
        ln -sf "$nginx_target" "$NGINX_SITES_ENABLED"
    fi

    nginx -t || die "Nginx config test failed. Check $nginx_target"
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx

    local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    local_ip="${local_ip:-localhost}"
    log "Dashboard available at http://$local_ip:$WEB_PORT/"
}

# The main execution sequence of the installer
main() {
    require_root

    echo "==============================================="
    echo " Pi Ping Monitor — Interactive Installation "
    echo "==============================================="

    detect_os
    install_bootstrap_deps
    ensure_project_files
    detect_real_user

    if [[ -f "$CONFIG_FILE" ]]; then
        IS_REINSTALL="true"
        log "Found existing system config. Loading defaults from $CONFIG_FILE..."
        load_env_file "$CONFIG_FILE"
    elif [[ -f "$SCRIPT_DIR/config.env" ]]; then
        log "Found local config.env. Loading defaults from $SCRIPT_DIR/config.env..."
        load_env_file "$SCRIPT_DIR/config.env"
    fi

    detect_defaults
    prompt_config
    setup_ssh_key_for_mac
    deploy_mac_helper
    setup_web_dashboard
    write_config
    install_service

    local local_ip
    local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    local_ip="${local_ip:-localhost}"

    echo
    echo "==============================================="
    echo " 🎉 INSTALLATION COMPLETE!"
    echo "==============================================="
    echo
    echo "📲 1. Automate App Settings"
    echo "Make sure your Automate flow on the Android phone ($AUTOMATE_HOST) is set up with:"
    echo "  • HTTP Server Port: $AUTOMATE_PORT"
    echo "  • Endpoint Path:    /$AUTOMATE_ENDPOINT"
    echo
    echo "🖥️  2. Dashboard URL"
    if [[ -n "$WEB_PORT" ]]; then
        echo "  http://$local_ip:$WEB_PORT/"
    else
        echo "  (Nginx setup skipped. Logs are in $LOG_DIR/)"
    fi
    echo
    echo "==============================================="
    echo
    echo "Done. Verify with:"
    echo "  systemctl status $SERVICE_NAME"
    echo "  tail -f $LOG_DIR/outages.log"
}

main "$@"
