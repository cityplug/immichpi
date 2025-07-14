#!/bin/bash
set -euo pipefail

# === Load Variables ===
CONFIG_FILE="./config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "❌ Configuration file $CONFIG_FILE not found."
    exit 1
fi

# === Ensure Required Commands Exist ===
REQUIRED_CMDS=(nmcli curl ufw tailscale tee docker lscpu vcgencmd ip free df awk grep)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Required command '$cmd' not found. Please install it."
        exit 1
    fi
done

# === Logging ===
LOG_FILE="/var/log/system_validation.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "### Starting System Validation ###"

# === Confirm Network Settings ===
echo "Interface: $INTERFACE"
echo "Static IP: $STATIC_IP"
echo "Gateway: $GATEWAY"
echo "DNS Servers: $DNS_SERVERS"

read -rp "Would you like to apply these network settings? (y/n): " apply_network
if [[ "$apply_network" =~ ^[Yy]$ ]]; then
    nmcli connection modify "$INTERFACE" ipv4.addresses "$STATIC_IP"
    nmcli connection modify "$INTERFACE" ipv4.gateway "$GATEWAY"
    nmcli connection modify "$INTERFACE" ipv4.dns "$DNS_SERVERS"
    nmcli connection modify "$INTERFACE" ipv4.method manual
    nmcli connection reload
    nmcli connection up "$INTERFACE"
    echo "✅ Network settings applied."
else
    echo "❌ Network settings skipped."
fi

# === Disable Unnecessary Services ===
echo "### Disabling Unused Services ###"
SERVICES=(bluetooth hciuart wpa_supplicant keyboard-setup modprobe@drm sys-kernel-tracing)
for svc in "${SERVICES[@]}"; do
    if systemctl list-units --full -all | grep -q "$svc.service"; then
        systemctl disable --now "$svc.service" && echo "✅ Disabled: $svc.service" || echo "⚠️ Could not disable $svc.service"
    else
        echo "ℹ️ Service not found: $svc.service"
    fi
done

# === Install Packages ===
echo "### Installing Required Packages ###"
apt update
PACKAGES=(git ufw curl ca-certificates gnupg software-properties-common zram-tools htop lm-sensors ssh-import-id)
for pkg in "${PACKAGES[@]}"; do
    dpkg -l | grep -qw "$pkg" || apt install -y "$pkg"
done

# === Install Cockpit ===
. /etc/os-release
echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" | tee /etc/apt/sources.list.d/backports.list
apt update && apt install -t ${VERSION_CODENAME}-backports -y cockpit
systemctl list-units | grep -q cockpit-motd && systemctl disable --now cockpit-motd.service

# === Clean MOTD ===
tee /etc/issue /etc/issue.net <<< "" > /dev/null
rm -f /etc/motd /etc/profile.d/wifi-check.sh
chmod -x /etc/update-motd.d/* 2>/dev/null || true

# === Custom MOTD ===
MOTD_SCRIPT="/etc/update-motd.d/00-custom"
tee "$MOTD_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash
RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
echo -e "${RED}System info as of:$(date)${NC}"
echo -e "${RED}OS:${NC} $(grep PRETTY_NAME /etc/os-release | cut -d '=' -f2 | tr -d '"')"
echo -e "${RED}Host:${NC} $(tr -d '\0' < /proc/device-tree/model)"
echo -e "${RED}Kernel:${NC} $(uname -r)"
echo -e "${RED}CPU:${NC} $(lscpu | grep 'Model name' | awk -F ':' '{print $2}' | xargs)"
echo -e "${YELLOW}CPU Temp:${NC} $(vcgencmd measure_temp | grep -oP '[0-9.]+')°C"
echo -e "${YELLOW}Load Avg:${NC} $(cut -d ' ' -f1-3 /proc/loadavg)"
echo -e "${YELLOW}Disk Usage:${NC} $(df -h / | awk 'NR==2{print $3 " used of " $2}')"
echo -e "${YELLOW}Memory Usage:${NC} $(free -m | awk '/Mem/{printf "%dMB / %dMB (%.1f%%)", $3, $2, $3*100/$2}')"
echo -e "${RED}IPv4:${NC}"; ip -4 -o addr show | awk '{print "  " $2 ": " $4}'
if command -v docker &>/dev/null; then
    echo -e "${BLUE}Docker Containers:${NC} $(docker ps -q | wc -l)"
    docker ps --format "  Container: {{.Names}} {{.Status}} Ports: {{.Ports}}"
fi
EOF
chmod +x "$MOTD_SCRIPT"
echo "alias $HOSTNAME='sudo $MOTD_SCRIPT'" >> ~/.bashrc && source ~/.bashrc

# === SSH Hardening ===
echo "### Securing SSH ###"
mkdir -p "/home/$USERNAME/.ssh" && chmod 700 "/home/$USERNAME/.ssh"
ssh-import-id-gh "${SSH_GITHUB_USER}" || echo "⚠️ Failed to import SSH keys"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

while true; do
    read -rp "Enter new SSH port (1024–65535): " SSH_PORT
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )) && break
    echo "Invalid port. Try again."
done

cp "$SSH_CONFIG" "$SSH_CONFIG.bak"
sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
sed -i 's/^#?PermitRootLogin .*/PermitRootLogin no/' "$SSH_CONFIG"
sed -i 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' "$SSH_CONFIG"
systemctl restart sshd && echo "✅ SSH updated"

# === UFW Configuration ===
echo "### Configuring Firewall ###"
ufw allow from 10.1.1.0/24 to any
ufw delete allow 22 2>/dev/null || true
ufw allow "$SSH_PORT"
ufw allow 9090/tcp
ufw default deny incoming
ufw default allow outgoing
ufw logging on
read -rp "Enable UFW now? (Y/n): " response
[[ "$response" =~ ^[Yy]?$ ]] && ufw enable

ufw status verbose

# === Enable IP Forwarding ===
echo "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
sysctl -p

# === Tailscale ===
echo "### Setting up Tailscale ###"
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh && echo "✅ Tailscale installed"
fi
read -rp "Connect to Tailscale? (y/n): " connect_tail
if [[ "$connect_tail" =~ ^[Yy]$ ]]; then
    read -rp "Advertise as exit node? (y/n): " adv_exit
    TS_OPTS=""
    [[ "$adv_exit" =~ ^[Yy]$ ]] && TS_OPTS="--advertise-exit-node"
    tailscale up --advertise-routes=192.168.41.0/24 $TS_OPTS
fi

# === System Update ===
apt full-upgrade -y && apt autoremove -y

# === Docker Setup ===
echo "### Docker Installation ###"
read -rp "Install Docker? (y/n): " docker_choice
if [[ "$docker_choice" =~ ^[Yy]$ ]]; then
    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose
    else
        echo "✅ Docker already installed"
    fi
    systemctl enable docker
    for group in docker ssh-users; do
        getent group "$group" && usermod -aG "$group" "$USERNAME"
    done
fi

# === Fan Script ===
[[ -x ./fan_temp.sh ]] && ./fan_temp.sh || echo "⚠️ fan_temp.sh not found or not executable."

# === Reboot Prompt ===
read -rp "Setup complete. Reboot now? (y/n): " reboot_choice
[[ "$reboot_choice" =~ ^[Yy]$ ]] && echo "Rebooting..." && sleep 5 && reboot || echo "Reboot skipped."
