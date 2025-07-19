#!/bin/bash
set -euo pipefail

# === ROOT CHECK ===
if [[ "$EUID" -ne 0 ]]; then
    echo "❌ This script must be run as root."
    exit 1
fi

# === Ask Before Installing Packages ===
echo "📦 The script will update APT and install base packages."
read -rp "Proceed with package installation? (y/n): " install_choice
if [[ "$install_choice" =~ ^[Yy]$ ]]; then
    echo "📦 Updating APT and installing required packages..."
    apt update
    apt install -y \
      network-manager \
      openssh-server \
      ufw \
      curl \
      sudo \
      cockpit \
      docker.io \
      docker-compose
else
    echo "❌ Skipping package installation."
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
    grep -q "^$var=" /etc/environment && \
        sed -i "s|^$var=.*|$var=\"${!var}\"|" /etc/environment || \
        echo "$var=\"${!var}\"" >> /etc/environment
done

# === Docker Setup ===
function docker_setup() {
    read -rp "Install Docker? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        systemctl enable docker
        usermod -aG docker "$USERNAME"
        echo "✅ Docker installed and user added to docker group."
    fi
}

# === Tailscale Setup ===
function tailscale_setup() {
    read -rp "Install Tailscale? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        curl -fsSL https://tailscale.com/install.sh | sh
        read -rp "Advertise as exit node? (y/n): " adv_exit
        OPTS=""
        [[ "$adv_exit" =~ ^[Yy]$ ]] && OPTS="--advertise-exit-node"
        tailscale up --advertise-routes="$TS_ADVERTISE_ROUTES" $OPTS
    fi
}

# === Fan Control ===
function fan_control_setup() {
    read -rp "Configure fan temperature control? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        read -rp "Set fan activation temperature in °C (40–85): " temp_c
        if [[ "$temp_c" =~ ^[0-9]+$ ]] && ((temp_c >= 40 && temp_c <= 85)); then
            temp_millic=$((temp_c * 1000))
            sed -i '/^dtoverlay=rpi-fan/d' /boot/firmware/config.txt
            echo "dtoverlay=rpi-fan,temp=$temp_millic" >> /boot/firmware/config.txt
            echo "$temp_millic" > /etc/fan_temp.conf
            echo "✅ Fan temperature set to ${temp_c}°C"
        else
            echo "❌ Invalid temperature."
        fi
    fi
}

# === Mount Immich Drive ===
function mount_immich_drive() {
    IMMICH_MOUNT="/immichpi"
    DEV_LABEL="immich-nvme"
    DEV_PATH=$(blkid -L "$DEV_LABEL" || true)

    if [[ -z "$DEV_PATH" ]]; then
        echo "❌ Could not find device with label '$DEV_LABEL'"
        return 1
    fi

    if ! grep -qs "$IMMICH_MOUNT" /proc/mounts; then
        mkdir -p "$IMMICH_MOUNT"
        mount "$DEV_PATH" "$IMMICH_MOUNT"
        chown "$USERNAME:$USERNAME" "$IMMICH_MOUNT"
        chmod 755 "$IMMICH_MOUNT"
    fi

    if ! grep -q "$DEV_LABEL" /etc/fstab; then
        echo "LABEL=$DEV_LABEL $IMMICH_MOUNT ext4 defaults 0 2" >> /etc/fstab
    fi

    echo "✅ Mounted $DEV_LABEL to $IMMICH_MOUNT"
}

# === Immich Setup ===
function immich_setup() {
    read -rp "Install Immich? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        mount_immich_drive || return 1
        IMMICH_DIR="/immichpi/appdata/immich"
        mkdir -p "$IMMICH_DIR"
        chown -R "$USERNAME:$USERNAME" "$IMMICH_DIR"

        echo "Configure Immich DB Password"
        while true; do
            read -rsp "Password: " DB_PASSWORD; echo
            read -rsp "Confirm: " DB_PASSWORD_CONFIRM; echo
            [[ "$DB_PASSWORD" == "$DB_PASSWORD_CONFIRM" ]] && break || echo "Mismatch. Try again."
        done

        cd "$IMMICH_DIR"
        curl -fsSL https://raw.githubusercontent.com/cityplug/immichpi/refs/heads/main/docker-compose.yml -o docker-compose.yml
        tee .env > /dev/null <<EOF
UPLOAD_LOCATION=/immichpi/appdata/immich/library
DB_DATA_LOCATION=/immichpi/appdata/immich/postgres
TZ=Europe/London
IMMICH_VERSION=release
DB_PASSWORD=$DB_PASSWORD
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
EOF
        chown "$USERNAME:$USERNAME" .env
        chmod 600 .env

        docker compose up -d
        docker ps
    fi
}

# === Immich Remove ===
function immich_cleanup() {
    IMMICH_DIR="/immichpi/appdata/immich"
    read -rp "⚠️ This will stop and remove all Immich containers and delete data in $IMMICH_DIR. Proceed? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker compose -f "$IMMICH_DIR/docker-compose.yml" down || true
        rm -rf "$IMMICH_DIR"
        echo "✅ Immich containers and data removed."
    else
        echo "❌ Operation cancelled."
    fi
}

# === Auto Run ===
function autorun_setup() {
    configure_hostname
    configure_networking
    disable_services
    ssh_setup
    ufw_setup
    docker_setup
    tailscale_setup
    fan_control_setup
    mount_immich_drive
    immich_setup
}

# === Reboot ===
function reboot_server() {
    read -rp "Are you sure you want to reboot now? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "🔄 Rebooting..."
        reboot
    else
        echo "❌ Reboot cancelled."
    fi
}

# === Menu ===
function menu() {
    while true; do
        echo -e "\n===== System Setup Menu ====="
        echo "1. Configure Hostname"
        echo "2. Configure Networking"
        echo "3. Disable Unused Services"
        echo "4. SSH Setup"
        echo "5. UFW Firewall Setup"
        echo "6. Install Docker"
        echo "7. Tailscale Setup"
        echo "8. Fan Control Setup"
        echo "9. Mount Immich NVMe"
        echo "10. Immich Setup"
        echo "11. Auto Run Full Setup"
        echo "12. Remove Immich + Data"
        echo "13. Reboot Server"
        echo "0. Exit"
        echo "============================="
        read -rp "Select an option: " choice
        case "$choice" in
            1) configure_hostname;;
            2) configure_networking;;
            3) disable_services;;
            4) ssh_setup;;
            5) ufw_setup;;
            6) docker_setup;;
            7) tailscale_setup;;
            8) fan_control_setup;;
            9) mount_immich_drive;;
            10) immich_setup;;
            11) autorun_setup;;
            12) immich_cleanup;;
            13) reboot_server;;
            0) echo "Exiting..."; break;;
            *) echo "❌ Invalid selection.";;
        esac
    done
}

# === Run Menu ===
menu
