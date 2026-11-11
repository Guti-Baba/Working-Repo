
#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Azure VPS WireGuard VPN Server Setup
# ==========================================

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/wg0.conf"

WG_PORT="51820"
WG_SUBNET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1/24"
CLIENT_IP="10.8.0.2/32"

CLIENT_CONF_NAME="wg-client.conf"

# ==========================================
# Root check
# ==========================================

if [[ $EUID -ne 0 ]]; then
    echo "[!] Run with sudo: sudo bash setup-wireguard.sh"
    exit 1
fi

# ==========================================
# Prevent overwriting existing configuration
# ==========================================

if [[ -f "$WG_CONF" ]]; then
    echo "[!] WireGuard configuration already exists."
    echo "[!] Aborting to protect existing configuration."
    exit 1
fi

# ==========================================
# Install dependencies
# ==========================================

echo "[+] Installing dependencies..."

apt-get update
apt-get install -y wireguard iptables curl

# ==========================================
# Detect public IP
# ==========================================

echo "[+] Detecting Azure public IP..."

if ! SERVER_ENDPOINT=$(curl -4fsS --max-time 15 https://api.ipify.org); then
    echo "[!] Failed to detect public IP."
    exit 1
fi

SERVER_ENDPOINT=$(printf '%s' "$SERVER_ENDPOINT" | tr -d '\r\n')

if [[ -z "$SERVER_ENDPOINT" ]]; then
    echo "[!] Public IP detection returned empty."
    exit 1
fi

echo "[+] Public IP: $SERVER_ENDPOINT"

# ==========================================
# Detect network interface
# ==========================================

echo "[+] Detecting network interface..."

WAN_IF=$(ip route get 1.1.1.1 | awk '{
    for(i=1;i<=NF;i++)
        if($i=="dev") {
            print $(i+1)
            exit
        }
}')

if [[ -z "$WAN_IF" ]]; then
    echo "[!] Network interface detection failed."
    exit 1
fi

echo "[+] Network interface: $WAN_IF"

# ==========================================
# Determine client configuration location
# ==========================================

CLIENT_OWNER="root"
CLIENT_HOME="/root"

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    CLIENT_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CLIENT_OWNER="$SUDO_USER"
fi

if [[ -z "$CLIENT_HOME" || ! -d "$CLIENT_HOME" ]]; then
    echo "[!] Could not determine client config directory."
    exit 1
fi

CLIENT_CONF="$CLIENT_HOME/$CLIENT_CONF_NAME"

# ==========================================
# Create WireGuard directory
# ==========================================

echo "[+] Creating WireGuard directory..."

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

umask 077

# ==========================================
# Generate server and client keys
# ==========================================

echo "[+] Generating keys..."

SERVER_PRIVATE_KEY=$(wg genkey)
SERVER_PUBLIC_KEY=$(printf '%s' "$SERVER_PRIVATE_KEY" | wg pubkey)

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(printf '%s' "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Save server keys

printf '%s\n' "$SERVER_PRIVATE_KEY" > "$WG_DIR/server_private.key"
printf '%s\n' "$SERVER_PUBLIC_KEY" > "$WG_DIR/server_public.key"

chmod 600 "$WG_DIR/server_private.key"
chmod 644 "$WG_DIR/server_public.key"

# ==========================================
# Enable IPv4 forwarding
# ==========================================

echo "[+] Enabling IPv4 forwarding..."

cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system

# ==========================================
# Generate server configuration
# ==========================================

echo "[+] Creating server configuration..."

cat > "$WG_CONF" <<EOF
[Interface]
Address = $WG_SERVER_IP
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY

PostUp = iptables -I FORWARD 1 -i %i -o $WAN_IF -j ACCEPT; iptables -I FORWARD 1 -i $WAN_IF -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG_SUBNET -o $WAN_IF -j MASQUERADE

PostDown = iptables -D FORWARD -i %i -o $WAN_IF -j ACCEPT; iptables -D FORWARD -i $WAN_IF -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG_SUBNET -o $WAN_IF -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP
EOF

chmod 600 "$WG_CONF"

# ==========================================
# Generate Windows client configuration
# ==========================================

echo "[+] Creating Windows client configuration..."

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = 10.8.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF"

if [[ "$CLIENT_OWNER" != "root" ]]; then
    chown "$CLIENT_OWNER" "$CLIENT_CONF"
fi

# ==========================================
# Configure UFW if active
# ==========================================

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "[+] Configuring UFW..."
    ufw allow "$WG_PORT/udp"
fi

# ==========================================
# Start WireGuard
# ==========================================

echo "[+] Enabling WireGuard service..."

# systemctl enable --now wg-quick@wg0
sudo wg-quick up wg0


# ==========================================
# Display results
# ==========================================

echo
echo "=========================================="
echo "       WIREGUARD SETUP COMPLETE"
echo "=========================================="

echo
echo "[+] Public IP:          $SERVER_ENDPOINT"
echo "[+] Network interface:  $WAN_IF"
echo "[+] VPN server IP:      10.8.0.1"
echo "[+] VPN client IP:      10.8.0.2"
echo "[+] VPN subnet:         $WG_SUBNET"
echo "[+] Listening port:     $WG_PORT/UDP"

echo
echo "[+] Server public key:"
echo "$SERVER_PUBLIC_KEY"

echo
echo "[+] Server configuration:"
echo "$WG_CONF"

echo
echo "[+] Windows client configuration:"
echo "$CLIENT_CONF"

echo
echo "[+] WireGuard status:"
wg show

echo
echo "=========================================="
echo "[!] Azure NSG: Allow inbound UDP $WG_PORT."
echo "[!] Import the client config into Windows."
echo "[!] Keep the client config private."
echo "=========================================="
