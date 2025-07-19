#!/bin/bash
set -euo pipefail

# === ROOT CHECK ===
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ This script must be run as root."
    exit 1
fi

# === Load Configuration ===
CONFIG_FILE="./config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "❌ Configuration file $CONFIG_FILE not found."
    exit 1
fi

# === Validate and Prompt for Required Variables ===
REQUIRED_VARS=(HOSTNAME USERNAME INTERFACE STATIC_IP GATEWAY DNS_SERVERS SSH_CONFIG SSH_KEYS_URL COCKPIT_PORT TS_ADVERTISE_ROUTES)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        read -rp "⚠️ Required variable '$var' is not set. Please enter a value: " val
        export "$var"="$val"
    fi
    echo "✅ $var=${!var}"
    export $var
    echo "$var=\"${!var}\"" >> /etc/environment
done

# === Detect Interface (fallback to wlan0) ===
if ip link show "$INTERFACE" &>/dev/null && ip link show "$INTERFACE" | grep -q "state UP"; then
    echo "✅ Using interface: $INTERFACE"
else
    INTERFACE="wlan0"
    echo "⚠️ Ethernet not available. Falling back to Wi-Fi interface: $INTERFACE"
fi

# Ensure required commands are available
REQUIRED_CMDS=(ufw nmcli curl tee systemctl ip)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# === Ensure User Exists ===
if ! id "$USERNAME" &>/dev/null; then
    echo "❌ User '$USERNAME' does not exist."
    exit 1
fi

# === Logging Setup ===
LOG_FILE="/var/log/system_validation.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== System Setup Started: $(date) ==="

# === Hostname ===
read -rp "Set system hostname to '$HOSTNAME'? (y/n): " set_hostname
if [[ "$set_hostname" =~ ^[Yy]$ ]]; then
    hostnamectl set-hostname "$HOSTNAME"
    echo "✅ Hostname set to $HOSTNAME"
else
    echo "❌ Hostname not changed."
fi

# === Network Configuration ===
echo "Interface: $INTERFACE"
echo "Static IP: $STATIC_IP"
echo "Gateway: $GATEWAY"
echo "DNS Servers: $DNS_SERVERS"
read -rp "Apply these network settings? (y/n): " apply_net
if [[ "$apply_net" =~ ^[Yy]$ ]]; then
    nmcli connection modify "$INTERFACE" ipv4.addresses "$STATIC_IP"
    nmcli connection modify "$INTERFACE" ipv4.gateway "$GATEWAY"
    nmcli connection modify "$INTERFACE" ipv4.dns "$DNS_SERVERS"
    nmcli connection modify "$INTERFACE" ipv4.method manual
    nmcli connection reload
    nmcli connection up "$INTERFACE"
    echo "✅ Network settings applied."
else
    echo "❌ Network config skipped."
fi

# === Disable Unused Services ===
read -rp "Disable unnecessary services (Bluetooth, wpa_supplicant, etc)? (y/n): " disable_services
if [[ "$disable_services" =~ ^[Yy]$ ]]; then
    echo "### Disabling Unnecessary Services ###"
    SERVICES=(bluetooth hciuart wpa_supplicant keyboard-setup modprobe@drm sys-kernel-tracing)
    for svc in "${SERVICES[@]}"; do
        systemctl list-units | grep -q "$svc" && systemctl disable --now "$svc" && echo "Disabled: $svc"
    done
else
    echo "❌ Service disabling skipped."
fi

# === SSH Setup ===
read -rp "Configure SSH with keys and port? (y/n): " ssh_choice
if [[ "$ssh_choice" =~ ^[Yy]$ ]]; then
    sudo mkdir -p "/home/$USERNAME/.ssh"
    sudo chmod 700 "/home/$USERNAME/.ssh"
    SSH_KEYS=$(curl -fsSL "$SSH_KEYS_URL")
    if [[ -z "$SSH_KEYS" ]]; then
        echo "❌ No SSH keys found at $SSH_KEYS_URL."
        read -rp "Paste your public SSH key: " SSH_KEYS
    fi
    echo "$SSH_KEYS" | sudo tee "/home/$USERNAME/.ssh/authorized_keys" > /dev/null
    sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

    while true; do
        read -rp "Enter new SSH port (1024–65535): " SSH_PORT
        [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) && break
        echo "Invalid port."
    done

    cp "$SSH_CONFIG" "$SSH_CONFIG.bak"
    sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
    sed -i 's/^#?PermitRootLogin .*/PermitRootLogin no/' "$SSH_CONFIG"
    sed -i 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' "$SSH_CONFIG"
    systemctl restart sshd && echo "✅ SSH updated"
else
    echo "❌ SSH configuration skipped."
fi

# === UFW Setup ===
read -rp "Configure UFW firewall? (y/n): " ufw_choice
if [[ "$ufw_choice" =~ ^[Yy]$ ]]; then
    ufw allow from 10.1.1.0/24 to any
    ufw status | grep -qw "22" && ufw delete allow 22
    ufw allow "$SSH_PORT"
    ufw allow "${COCKPIT_PORT}/tcp"
    ufw default deny incoming
    ufw default allow outgoing
    ufw logging on
    read -rp "Enable UFW? (Y/n): " ufw_enable
    [[ "$ufw_enable" =~ ^[Yy]?$ ]] && ufw --force enable
    ufw status verbose
else
    echo "❌ UFW setup skipped."
fi

# === Docker Setup ===
read -rp "Install Docker? (y/n): " docker_choice
if [[ "$docker_choice" =~ ^[Yy]$ ]]; then
    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose
    fi
    systemctl enable docker
    for group in docker ssh-users; do
        getent group "$group" || groupadd "$group"
        usermod -aG "$group" "$USERNAME"
    done
    echo "✅ Docker installed and user added to groups."
else
    echo "❌ Docker installation skipped."
fi

# === MOTD Customization ===
echo "❌ MOTD customization skipped."

# === System Updates ===
read -rp "Run system update and cleanup? (y/n): " update_choice
if [[ "$update_choice" =~ ^[Yy]$ ]]; then
    apt update && apt full-upgrade -y && apt autoremove -y
    echo "✅ System updated."
else
    echo "❌ System update skipped."
fi

# === Tailscale ===
read -rp "Install and configure Tailscale? (y/n): " ts_choice
if [[ "$ts_choice" =~ ^[Yy]$ ]]; then
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    read -rp "Advertise as exit node? (y/n): " adv_exit
    OPTS=""
    [[ "$adv_exit" =~ ^[Yy]$ ]] && OPTS="--advertise-exit-node"
    tailscale up --advertise-routes="$TS_ADVERTISE_ROUTES" $OPTS
    echo "✅ Tailscale setup complete."
else
    echo "❌ Tailscale setup skipped."
fi

# === Fan Control ===
read -rp "Set fan activation temperature (°C, 40–85 recommended)? (y/n): " fan_choice
if [[ "$fan_choice" =~ ^[Yy]$ ]]; then
    read -rp "Enter desired fan activation temperature (°C): " temp_c
    if ! [[ "$temp_c" =~ ^[0-9]+$ ]] || (( temp_c < 40 || temp_c > 85 )); then
        echo "❌ Invalid temperature input."
    else
        temp_millic=$((temp_c * 1000))
        sed -i '/^dtoverlay=rpi-fan/d' /boot/firmware/config.txt
        echo "dtoverlay=rpi-fan,temp=$temp_millic" >> /boot/firmware/config.txt
        echo "$temp_millic" > /etc/fan_temp.conf
        grep -q "dtoverlay=rpi-fan,temp=$temp_millic" /boot/firmware/config.txt && echo "✅ Fan temperature set to ${temp_c}°C" || echo "❌ Failed to confirm fan setting."
    fi
else
    echo "❌ Fan control skipped."
fi

# === Summary & Reboot ===
echo -e "\n✅ Setup Complete:"
echo " - Hostname: $HOSTNAME"
echo " - Interface: $INTERFACE"
echo " - SSH Port: ${SSH_PORT:-Not Set}"
echo " - Firewall: $(ufw status | grep -q active && echo Enabled || echo Disabled)"
echo " - Docker Installed: $(command -v docker &>/dev/null && echo Yes || echo No)"
echo " - Tailscale: $(command -v tailscale &>/dev/null && echo Installed || echo Not Installed)"
echo " - Fan Temp: $(cat /etc/fan_temp.conf 2>/dev/null || echo Not Set)"

read -rp "Reboot now? (y/n): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && reboot
