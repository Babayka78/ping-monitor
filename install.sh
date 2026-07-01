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
CROSS_CHECK=""
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
WS_INSTALLED=""
SETUP_NGINX="Y"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

secret() {
    printf '%s' "$1" | rev | openssl base64 -A
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

hr() {
    printf '%s\n' "============================================================="
}

section() {
    echo
    hr
    printf ' %s\n' "$1"
    hr
}

subsection() {
    echo
    printf '%s\n' "-------------------------------------------------------------"
    printf ' %s\n' "$1"
    printf '%s\n' "-------------------------------------------------------------"
}

command_block() {
    local cmd
    echo
    for cmd in "$@"; do
        printf '                  %s\n' "$cmd"
    done
    echo
}

is_from_env() {
    if [[ "${IS_REINSTALL:-false}" == "true" ]]; then
        return 1
    fi
    local var_name="$1"
    [[ -z "$var_name" ]] && return 1
    local loaded_var="ENV_LOADED_${var_name}"
    [[ "${!loaded_var:-}" == "true" ]]
}

kv() {
    local label="$1"
    local key="$2"
    local value="$3"
    local star=" "
    if is_from_env "$key"; then
        star="*"
    fi
    printf '  %-23s %-17s %s = %s\n' "[$label]" "$key" "$star" "${value:-N/A}"
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
        local ans
        read -r -p "Install missing packages now? [Y/n]: " ans
        ans="${ans:-Y}"
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            log "Installing missing packages..."
            apt_install "${missing_deps[@]}"
        else
            die "Cannot proceed without required dependencies. Please install them manually."
        fi
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
# Note: This simple parser does not support multi-line values (e.g., multiline SSH keys).
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
            TARGET_MAIN|CROSS_CHECK|TARGET_MAC|HOTSPOT_SSID|HOTSPOT_PASSWORD|AUTOMATE_HOST|AUTOMATE_PORT|AUTOMATE_ENDPOINT|SSH_USER|SSH_KEY_PATH|MAIN_INTERVAL|SIDE_INTERVAL|DEBUG|WEB_PORT)
                printf -v "$key" '%s' "$value"
                if [[ -n "$value" ]]; then
                    printf -v "ENV_LOADED_${key}" '%s' "true"
                fi
                ;;
        esac
    done < <(grep '=' "$file")
}

# Tries to auto-detect the ISP router IP and sets default values for variables
detect_defaults() {
    local isp_gw=""
    log "Detecting ISP router via ip route..."
    isp_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)"
    is_valid_ipv4 "$isp_gw" || isp_gw=""

    TARGET_MAIN="${TARGET_MAIN:-${isp_gw:-192.168.100.1}}"
    CROSS_CHECK="${CROSS_CHECK:-}"
    TARGET_MAC="${TARGET_MAC:-}"
    SSH_USER="${SSH_USER:-}"
    SSH_KEY_PATH="${SSH_KEY_PATH:-$REAL_HOME/.ssh/id_ed25519_ping_monitor}"
    HOTSPOT_SSID="${HOTSPOT_SSID:-}"
    HOTSPOT_PASSWORD="${HOTSPOT_PASSWORD:-}"
    AUTOMATE_HOST="${AUTOMATE_HOST:-}"
    AUTOMATE_PORT="${AUTOMATE_PORT:-7801}"
    AUTOMATE_ENDPOINT="${AUTOMATE_ENDPOINT:-failover_$(random_suffix)}"
    MAIN_INTERVAL="${MAIN_INTERVAL:-5}"
    SIDE_INTERVAL="${SIDE_INTERVAL:-30}"
    DEBUG="${DEBUG:-false}"
    WEB_PORT="${WEB_PORT:-}"
}

# Helper function to format prompt labels consistently
format_prompt() {
    local label="$1"
    local var_name="$2"
    local full_label
    if [[ -n "$var_name" ]]; then
        full_label="$(printf "%-38s (%s)" "$label" "$var_name")"
    else
        full_label="$label"
    fi
    printf "%-65s" "$full_label"
}

# Helper function to ask the user a question with a default fallback
_read_input() {
    local label="$1"
    local var_name="$2"
    local current="$3"
    
    local star_bracket="[$current]"
    if is_from_env "$var_name"; then
        star_bracket="[${current}*]"
    fi
    
    local input
    read -e -r -p "$label $star_bracket: " input
    printf '%s' "${input:-$current}"
}

# Helper function to read user input with a default value and readline support
prompt_value() {
    local label
    label="$(format_prompt "$1" "$2")"
    _read_input "$label" "$2" "$3"
}

# Prompts for a password securely (hidden input) with confirmation
prompt_password() {
    local label
    label="$(format_prompt "$1" "$2")"
    local var_name="$2"
    local current="$3" input
    local star_bracket="[]"
    if [[ -n "$current" ]]; then
        if is_from_env "$var_name"; then
            star_bracket="[hidden*]"
        else
            star_bracket="[hidden]"
        fi
    fi

    while true; do
        read -r -s -p "$label $star_bracket: " input >&2
        echo >&2
        
        if [[ -z "$input" && -n "$current" ]]; then
            printf '%s' "$current"
            return 0
        fi

        if [[ -z "$input" ]]; then
            echo "[!] Password cannot be empty. Please try again." >&2
            continue
        fi

        local masked_input
        masked_input=$(printf "%${#input}s" | tr ' ' '*')
        echo "  Entered: $masked_input" >&2
        
        printf '%s' "$input"
        return 0
    done
}

# Checks if an IPv4 address is mathematically valid
is_valid_ipv4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        if (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && \
              BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 )); then
            return 0
        fi
    fi
    return 1
}

# Prompts for an IPv4 address and re-prompts until a valid one is entered.
prompt_ipv4() {
    local base_label="$1"
    local var_name="$2"
    local current="$3"
    local example="${4:-}"
    
    if [[ "${IS_REINSTALL:-false}" != "true" ]] && [[ -z "$current" ]] && [[ -n "$example" ]]; then
        base_label="$base_label (e.g. $example)"
    fi
    
    local label
    label="$(format_prompt "$base_label" "$var_name")"
    local input
    
    while true; do
        input="$(_read_input "$label" "$var_name" "$current")"
        if is_valid_ipv4 "$input"; then
            printf '%s' "$input"
            return 0
        fi
        echo "[!] '$input' is not a valid IPv4 address. Please try again." >&2
    done
}

# Prompts for an IPv4 address, but allows an empty string as a valid input.
prompt_optional_ipv4() {
    local base_label="$1"
    local var_name="$2"
    local current="$3"
    local example="${4:-}"
    
    if [[ "${IS_REINSTALL:-false}" != "true" ]] && [[ -z "$current" ]] && [[ -n "$example" ]]; then
        base_label="$base_label (e.g. $example)"
    fi
    
    local full_label
    if [[ -n "$var_name" ]]; then
        full_label="$(printf "%-38s (%s) (optional)" "$base_label" "$var_name")"
    else
        full_label="$base_label (optional)"
    fi
    local label
    label="$(printf "%-65s" "$full_label")"
    local input
    
    while true; do
        input="$(_read_input "$label" "$var_name" "$current")"
        if [[ -z "$input" ]]; then
            printf '%s' ""
            return 0
        fi
        if is_valid_ipv4 "$input"; then
            printf '%s' "$input"
            return 0
        fi
        echo "[!] '$input' is not a valid IPv4 address (or leave empty). Please try again." >&2
    done
}

# Prompts for a TCP port (1-65535) and re-prompts until a valid one is entered.
prompt_port() {
    local label
    label="$(format_prompt "$1" "$2")"
    local var_name="$2"
    local current="$3" input
    
    while true; do
        input="$(_read_input "$label" "$var_name" "$current")"
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
            printf '%s' "$input"
            return 0
        fi
        echo "[!] '$input' is not a valid port (1-65535). Please try again." >&2
    done
}

# Prompts for a non-empty value and re-prompts until one is entered.
prompt_nonempty() {
    local label
    label="$(format_prompt "$1" "$2")"
    local var_name="$2"
    local current="$3" input
    
    while true; do
        input="$(trim "$(_read_input "$label" "$var_name" "$current")")"
        if [[ -n "$input" ]]; then
            printf '%s' "$input"
            return 0
        fi
        echo "[!] This field cannot be empty. Please try again." >&2
    done
}

# Prompts for the SSH key path, allowing filename-only input and reconstructing absolute paths
prompt_ssh_key_path() {
    local default_key_name
    default_key_name="$(basename "$SSH_KEY_PATH")"
    local key_name
    key_name="$(prompt_nonempty 'SSH Key Path' 'SSH_KEY_PATH' "$default_key_name")"
    
    if [[ "$key_name" != "$default_key_name" ]]; then
        if [[ "$key_name" == */* ]]; then
            echo "$key_name"
        else
            echo "$REAL_HOME/.ssh/$key_name"
        fi
    else
        echo "$SSH_KEY_PATH"
    fi
}

# Guides the user through setting up all required IP addresses and credentials
prompt_config() {
    echo
    echo "--- Environment Configuration ---"
    if [[ "${IS_REINSTALL:-false}" == "true" ]]; then
        echo "Existing installation detected."
        echo "Press [Enter] to keep the current values loaded from $CONFIG_FILE."
        echo "The hotspot password is not shown and must be entered again."
    else
        echo "Press [Enter] to accept the suggested defaults."
        if [[ -f "$SCRIPT_DIR/config.env" ]]; then
            echo "Defaults loaded from local ./config.env are marked with *."
        fi
    fi
    echo

    TARGET_MAIN="$(prompt_ipv4 'ISP Router IP' 'TARGET_MAIN' "$TARGET_MAIN" '192.168.100.1')"
    CROSS_CHECK="$(prompt_optional_ipv4 'Secondary IP' 'CROSS_CHECK' "$CROSS_CHECK" '192.168.100.79')"
    TARGET_MAC="$(prompt_ipv4 'Mac Computer IP' 'TARGET_MAC' "$TARGET_MAC" '192.168.0.173')"
    SSH_USER="$(prompt_nonempty 'Mac SSH Username' 'SSH_USER' "$SSH_USER")"
    SSH_KEY_PATH="$(prompt_ssh_key_path)"
    HOTSPOT_SSID="$(prompt_nonempty 'Phone Hotspot SSID' 'HOTSPOT_SSID' "$HOTSPOT_SSID")"
    HOTSPOT_PASSWORD="$(prompt_password 'Phone Hotspot Password' 'HOTSPOT_PASSWORD' "$HOTSPOT_PASSWORD")"
    AUTOMATE_HOST="$(prompt_ipv4 'Android Phone IP' 'AUTOMATE_HOST' "$AUTOMATE_HOST" '192.168.0.65')"
    AUTOMATE_PORT="$(prompt_port 'Automate HTTP Port' 'AUTOMATE_PORT' "$AUTOMATE_PORT")"
    AUTOMATE_ENDPOINT="$(prompt_nonempty 'Automate Endpoint' 'AUTOMATE_ENDPOINT' "$AUTOMATE_ENDPOINT")"
    
    local enable_debug_default="N"
    if [[ "$DEBUG" == "true" ]]; then enable_debug_default="Y"; fi
    local enable_debug
    
    local star_bracket="[$enable_debug_default]"
    if is_from_env "DEBUG"; then
        star_bracket="[${enable_debug_default}*]"
    fi
    
    read -r -p "$(format_prompt 'Enable debug logging?' 'DEBUG') $star_bracket: " enable_debug
    enable_debug="${enable_debug:-$enable_debug_default}"
    if [[ "$enable_debug" =~ ^[Yy]$ ]]; then
        DEBUG="true"
    else
        DEBUG="false"
    fi
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

    section "Before copying the key to your Mac:"
    echo "  1. Enable Remote Login on the Mac"
    echo "  2. Ensure user '$SSH_USER' is allowed to log in via SSH"
    echo "  3. Ensure the Mac is reachable at $TARGET_MAC"
    echo

    if sudo -u "$REAL_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 \
         -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" true >/dev/null 2>&1 || \
       sudo -u "$REAL_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 \
         -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" check_lid >/dev/null 2>&1; then
        log "SSH key auth already works, skipping ssh-copy-id."
    else
        read -r -p "Copy SSH public key to Mac now using ssh-copy-id? $prompt_str: " copy_now
        copy_now="${copy_now:-$def_ans}"

        if [[ "$copy_now" =~ ^[Yy]$ ]]; then
            subsection "🔐 ATTENTION: The system will now prompt for the Mac password
    for user '$SSH_USER'. Characters will be hidden."
            if sudo -u "$REAL_USER" ssh-copy-id -i "$pubkey" "$SSH_USER@$TARGET_MAC"; then
                log "SSH public key installed successfully on the Mac."
            else
                warn "ssh-copy-id failed. Run this manually after enabling Remote Login on the Mac:"
                command_block "sudo -u \"$REAL_USER\" ssh-copy-id -i \"$pubkey\" \"$SSH_USER@$TARGET_MAC\""
            fi
        else
            echo "Run this manually when ready:"
            command_block "sudo -u \"$REAL_USER\" ssh-copy-id -i \"$pubkey\" \"$SSH_USER@$TARGET_MAC\""
        fi
    fi

    read -r -p "Test SSH connectivity to the Mac now? [Y/n]: " test_now
    test_now="${test_now:-Y}"
    if [[ "$test_now" =~ ^[Yy]$ ]]; then
        if sudo -u "$REAL_USER" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" 'echo SSH_OK' >/dev/null 2>&1 || \
           sudo -u "$REAL_USER" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" check_lid >/dev/null 2>&1; then
            log "SSH test succeeded."
        else
            warn "SSH test failed. You can continue, but failover actions may not work until SSH access is fixed."
        fi
    fi
}

# Creates the helper environment on the Mac and restricts the SSH key
deploy_mac_helper() {
    log "Deploying restricted SSH helper to Mac..."
    
    local safe_pass_enc
    safe_pass_enc="$(secret "$HOTSPOT_PASSWORD")"
    local safe_ssid="${HOTSPOT_SSID//\'/\'\\\'\'}"
    local pubkey_content
    pubkey_content="$(cat "${SSH_KEY_PATH}.pub")"

    # Base SSH command
    local ssh_cmd_arr=(sudo -u "$REAL_USER" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    local auth_opts_arr=(-o BatchMode=yes -i "$SSH_KEY_PATH")
    
    # Check if the key is restricted
    local check_output
    check_output=$("${ssh_cmd_arr[@]}" "${auth_opts_arr[@]}" "$SSH_USER@$TARGET_MAC" true 2>&1 || true)

    if [[ "$check_output" == *"Access Denied"* ]]; then
        log "SSH key is already restricted. We need your Mac password to bypass the restriction and update the files."
        auth_opts_arr=(-o PubkeyAuthentication=no)
        subsection "🔐 ATTENTION: The system will prompt for the Mac password again
    to bypass current key restrictions and update the script."
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
HOTSPOT_PASSWORD='${safe_pass_enc}'
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
    if "${ssh_cmd_arr[@]}" "${auth_opts_arr[@]}" "$SSH_USER@$TARGET_MAC" 'bash -s' <<< "$deploy_payload" | grep -q "DEPLOY_SUCCESS"; then
        log "Mac environment updated and SSH key restricted successfully."
    else
        warn "Failed to update Mac environment."
        return 1
    fi
}

# Saves the final configuration variables to the system config file
write_config() {
    log "Saving configuration to $CONFIG_FILE..."
    install -d -m 700 -o "$REAL_USER" -g "$REAL_USER" "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<'EOF_CONF'
# Generated by install.sh
EOF_CONF
    for key in TARGET_MAIN CROSS_CHECK TARGET_MAC HOTSPOT_SSID AUTOMATE_HOST AUTOMATE_PORT AUTOMATE_ENDPOINT SSH_USER SSH_KEY_PATH MAIN_INTERVAL SIDE_INTERVAL DEBUG WEB_PORT; do
        printf "%s='%s'\n" "$key" "${!key//\'/\'\\\'\'}" >> "$CONFIG_FILE"
    done
    chown "$REAL_USER:$REAL_USER" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

# Copies the script to /usr/local/bin and enables the systemd background service
install_service() {
    log "Installing ping-monitor service..."
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
    fi
    install -m 755 "$SCRIPT_DIR/ping-monitor.sh" "$INSTALL_BIN"
    install -d -m 755 -o "$REAL_USER" -g "$REAL_USER" "$LOG_DIR" "$STATE_DIR"
    
    # Pre-create log files so 'tail -f' works immediately after installation
    touch "$LOG_DIR/outages.log" "$LOG_DIR/debug.log"
    chown "$REAL_USER:$REAL_USER" "$LOG_DIR/outages.log" "$LOG_DIR/debug.log"
    chmod 644 "$LOG_DIR/outages.log" "$LOG_DIR/debug.log"

    sed -e "s|@@REAL_USER@@|$REAL_USER|g" "$SCRIPT_DIR/ping-monitor.service" > "$SERVICE_FILE"
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    
    section "🚀 INSTALLATION ALMOST COMPLETE. START SERVICE?"
    local start_now
    read -r -p "Start the ping-monitor service now? [Y/n]: " start_now
    start_now="${start_now:-Y}"
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        systemctl enable --now "$SERVICE_NAME"
        log "Service started successfully."
    else
        systemctl enable "$SERVICE_NAME"
        log "Service enabled but NOT started. To start it later, run:"
        command_block "systemctl start $SERVICE_NAME"
    fi
}

# Checks if a specific port is already taken by another process
is_tcp_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -tln | awk -v p=":$port" '$4 ~ p "$" {found=1; exit} END {exit !found}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln | awk -v p=":$port" '$4 ~ p "$" {found=1; exit} END {exit !found}'
    else
        (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
    fi
}

# Finds the first available port for the web dashboard (tries 80, then 8080+)
select_dashboard_port() {
    local port

    if [[ -n "$WEB_PORT" ]]; then
        local is_ours="false"
        if [[ -f "$NGINX_SITES_ENABLED" ]] && grep -q -E "listen( \[::\])?:$WEB_PORT\b" "$NGINX_SITES_ENABLED" 2>/dev/null; then
            is_ours="true"
        elif [[ -f "$NGINX_CONF_D" ]] && grep -q -E "listen( \[::\])?:$WEB_PORT\b" "$NGINX_CONF_D" 2>/dev/null; then
            is_ours="true"
        fi

        if [[ "$is_ours" == "true" ]] || ! is_tcp_port_in_use "$WEB_PORT"; then
            printf '%s\n' "$WEB_PORT"
            return 0
        fi
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

# Prompts for dashboard setup, checks existing servers, and calculates a port
prompt_dashboard_setup() {
    WS_INSTALLED=""
    SETUP_NGINX="Y"

    subsection "Web Dashboard Setup"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        WS_INSTALLED="nginx"
    elif systemctl is-active --quiet apache2 2>/dev/null; then
        WS_INSTALLED="apache2"
    elif systemctl is-active --quiet caddy 2>/dev/null; then
        WS_INSTALLED="caddy"
    elif systemctl is-active --quiet lighttpd 2>/dev/null; then
        WS_INSTALLED="lighttpd"
    fi

    if [[ -n "$WS_INSTALLED" && "$WS_INSTALLED" != "nginx" ]]; then
        warn "Detected active web server: $WS_INSTALLED"
        read -r -p "Install Nginx alongside $WS_INSTALLED on a different port? [y/N]: " SETUP_NGINX
        SETUP_NGINX="${SETUP_NGINX:-N}"
        if [[ ! "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
            echo "    Nginx setup is skipped to avoid modifying an existing web stack."
            echo "    Serve dashboard files from: $LOG_DIR/"
            WEB_PORT=""
            return 0
        fi
    fi

    if [[ "$WS_INSTALLED" == "nginx" ]]; then
        read -r -p "Nginx is already active. Add/update ping-monitor dashboard config? [Y/n]: " SETUP_NGINX
        SETUP_NGINX="${SETUP_NGINX:-Y}"
    elif [[ -z "$WS_INSTALLED" ]]; then
        read -r -p "Install and configure Nginx for the dashboard? [Y/n]: " SETUP_NGINX
        SETUP_NGINX="${SETUP_NGINX:-Y}"
    fi

    if [[ ! "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
        log "Skipping web server setup."
        WEB_PORT=""
        return 0
    fi

    local suggested_port chosen_port is_our_port
    while true; do
        suggested_port="$(select_dashboard_port)"
        local star_bracket="[$suggested_port]"
        if is_from_env "WEB_PORT" && [[ "$suggested_port" == "$WEB_PORT" ]]; then
            star_bracket="[${suggested_port}*]"
        fi
        read -r -p "$(format_prompt 'Dashboard port' 'WEB_PORT') $star_bracket: " chosen_port
        chosen_port="${chosen_port:-$suggested_port}"
        
        is_our_port="false"
        if [[ -f "$NGINX_SITES_ENABLED" ]] && grep -q -E "listen( \[::\])?:$chosen_port\b" "$NGINX_SITES_ENABLED" 2>/dev/null; then
            is_our_port="true"
        elif [[ -f "$NGINX_CONF_D" ]] && grep -q -E "listen( \[::\])?:$chosen_port\b" "$NGINX_CONF_D" 2>/dev/null; then
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
}

# Installs Nginx, configures the dashboard site, and reloads the web server
setup_web_dashboard() {
    if [[ ! "$SETUP_NGINX" =~ ^[Yy]$ ]]; then
        return 0
    fi

    local nginx_target local_ip

    if [[ "$WS_INSTALLED" != "nginx" ]]; then
        log "Installing Nginx..."
        # Prevent Nginx from starting automatically during installation.
        # The trap on RETURN guarantees removal of policy-rc.d even if apt_install fails.
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod +x /usr/sbin/policy-rc.d
        trap 'rm -f /usr/sbin/policy-rc.d' RETURN
        
        apt_install nginx
        
        # Restore normal service startup policy and clear the function-scoped trap.
        rm -f /usr/sbin/policy-rc.d
        trap - RETURN
        
        # Remove default config that tries to bind to port 80
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi



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

run_self_tests() {
    subsection "Running Post-Installation Self-Tests"
    
    # 1. Check Systemd Service
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "[ OK ] Service $SERVICE_NAME is running."
    else
        echo "[WARN] Service $SERVICE_NAME is NOT running! Check:"
        command_block "systemctl status $SERVICE_NAME"
    fi

    # 2. Check Dashboard
    if [[ -n "$WEB_PORT" ]]; then
        if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$WEB_PORT/" | grep -q "^200$"; then
            echo "[ OK ] Web dashboard is reachable on port $WEB_PORT."
        else
            echo "[WARN] Web dashboard did not return HTTP 200. Check Nginx configuration."
        fi
    fi

    # 3. Check Mac SSH & Helper
    local _ssh_out
    _ssh_out=$(sudo -u "$REAL_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 -i "$SSH_KEY_PATH" "$SSH_USER@$TARGET_MAC" check_lid 2>/dev/null || echo "FAILED")
    if [[ "$_ssh_out" == "Yes" || "$_ssh_out" == "No" || "$_ssh_out" == "Unknown" ]]; then
        echo "[ OK ] Mac SSH helper is reachable (Lid state: $_ssh_out)."
    else
        echo "[WARN] Mac SSH helper test failed (Output: $_ssh_out). Ensure the Mac is online and the SSH key is allowed."
    fi
}

print_config_table() {
    local masked_pw="<hidden>"
    if [[ -n "$HOTSPOT_PASSWORD" ]]; then
        masked_pw=$(printf "%${#HOTSPOT_PASSWORD}s" | tr ' ' '*')
    fi

    kv "Main Router IP" "TARGET_MAIN" "$TARGET_MAIN"
    kv "Secondary IP" "CROSS_CHECK" "$CROSS_CHECK"
    kv "Mac Computer IP" "TARGET_MAC" "$TARGET_MAC"
    kv "Mac SSH Username" "SSH_USER" "$SSH_USER"
    kv "SSH Key Path" "SSH_KEY_PATH" "$SSH_KEY_PATH"
    kv "Hotspot SSID" "HOTSPOT_SSID" "$HOTSPOT_SSID"
    kv "Hotspot Password" "HOTSPOT_PASSWORD" "$masked_pw"
    kv "Android Phone IP" "AUTOMATE_HOST" "$AUTOMATE_HOST"
    kv "Automate Port" "AUTOMATE_PORT" "$AUTOMATE_PORT"
    kv "Automate Endpoint" "AUTOMATE_ENDPOINT" "/$AUTOMATE_ENDPOINT"
    kv "Debug Mode" "DEBUG" "$DEBUG"
    kv "Web Dashboard Port" "WEB_PORT" "${WEB_PORT:-N/A}"
}

# The main execution sequence of the installer
main() {
    require_root
    detect_os
    install_bootstrap_deps
    ensure_project_files
    detect_real_user

    if [[ -f "$CONFIG_FILE" ]]; then
        IS_REINSTALL="true"
        section "Pi Ping Monitor — Interactive Re-installation"
        log "Found existing system config. Loading defaults from $CONFIG_FILE..."
        load_env_file "$CONFIG_FILE"
    else
        section "Pi Ping Monitor — Interactive Installation"
        if [[ -f "$SCRIPT_DIR/config.env" ]]; then
            IS_REINSTALL="false"
            log "Found local config.env. Loading defaults from $SCRIPT_DIR/config.env..."
            load_env_file "$SCRIPT_DIR/config.env"
        else
            IS_REINSTALL="false"
        fi
    fi

    detect_defaults
    
    if [[ "$IS_REINSTALL" == "true" ]]; then
        echo
        log "The monitor is currently installed with the following settings:"
        echo
        print_config_table
        echo
        
        local reconfigure
        read -r -p "Do you want to reconfigure these settings? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            log "Exiting without making changes."
            exit 0
        fi
    fi

    while true; do
        prompt_config
        prompt_dashboard_setup
        
        clear -x
        section "📋 PLEASE REVIEW YOUR CONFIGURATION:"
        print_config_table
        hr
        
        local conf_ok
        read -r -p "Is this correct? Enter 'n' to restart configuration. [Y/n]: " conf_ok
        if [[ "${conf_ok:-Y}" =~ ^[Yy]$ ]]; then
            break
        fi
        echo "Restarting configuration..."
    done

    setup_ssh_key_for_mac
    deploy_mac_helper || die "Mac helper deployment failed. Installation aborted."
    setup_web_dashboard
    write_config
    install_service

    run_self_tests

    local local_ip
    local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    local_ip="${local_ip:-localhost}"

    section "🎉 INSTALLATION COMPLETE!"
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

    echo "Done. Verify with:"
    command_block \
        "systemctl status $SERVICE_NAME" \
        "tail -f $LOG_DIR/outages.log"
}

main "$@"
