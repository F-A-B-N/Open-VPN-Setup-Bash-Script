#!/usr/bin/env bash
#
# OpenVPN 443 Auto Installer (hardened)
# Supports Ubuntu 20.04/22.04/24.04, Debian 11/12
# Works on AWS EC2 (IMDSv2), GCP, Azure, or bare metal with fallback.
#
set -euo pipefail

# ---------- Configuration ----------
VPN_USER="${VPN_USER:-client}"
PORT="${PORT:-443}"
PROTO="${PROTO:-tcp}"
VPN_NET="10.8.0.0"
VPN_MASK="255.255.255.0"
VPN_CIDR="${VPN_NET}/24"
CA_DIR="/root/openvpn-ca"
OVPN_DIR="/etc/openvpn"
CLIENT_DIR="/root/client-configs"
KEY_DIR="${OVPN_DIR}/keys"
LOG="/var/log/openvpn-installer.log"

# ---------- Helpers ----------
log()  { echo -e "\e[1;32m[+]\e[0m $*" | tee -a "$LOG"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*" | tee -a "$LOG" >&2; }
die()  { echo -e "\e[1;31m[x]\e[0m $*" | tee -a "$LOG" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"
}

detect_public_ip() {
    # Try IMDSv2 first (AWS)
    local token ip
    token=$(curl -sS -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [[ -n "${token:-}" ]]; then
        ip=$(curl -sS -m 3 -H "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    fi
    # Fallbacks
    [[ -z "${ip:-}" ]] && ip=$(curl -sS -m 3 https://api.ipify.org 2>/dev/null || true)
    [[ -z "${ip:-}" ]] && ip=$(curl -sS -m 3 https://ifconfig.me 2>/dev/null || true)
    [[ -z "${ip:-}" ]] && ip=$(hostname -I | awk '{print $1}')
    [[ -n "${ip:-}" ]] || die "Could not determine public IP"
    echo "$ip"
}

detect_default_iface() {
    ip -4 route show default | awk '{print $5; exit}'
}

# ---------- Preflight ----------
require_root
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

log "Detecting public IP..."
SERVER_IP=$(detect_public_ip)
log "Public IP: $SERVER_IP"

WAN_IFACE=$(detect_default_iface)
[[ -n "$WAN_IFACE" ]] || die "Could not detect default network interface"
log "WAN interface: $WAN_IFACE"

# ---------- Install packages ----------
export DEBIAN_FRONTEND=noninteractive
log "Installing packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
    openvpn easy-rsa iptables iptables-persistent curl ca-certificates

# ---------- Easy-RSA setup ----------
if [[ ! -d "$CA_DIR/pki" ]]; then
    log "Initializing PKI in $CA_DIR ..."
    make-cadir "$CA_DIR"
    cd "$CA_DIR"
    export EASYRSA_BATCH=1
    export EASYRSA_ALGO=ec
    export EASYRSA_CURVE=secp384r1
    export EASYRSA_DIGEST=sha512
    ./easyrsa init-pki
    ./easyrsa --req-cn="OpenVPN-CA" build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    ./easyrsa gen-req "$VPN_USER" nopass
    ./easyrsa sign-req client "$VPN_USER"
    ./easyrsa gen-crl
    openvpn --genkey secret "$CA_DIR/ta.key"
else
    log "PKI already exists at $CA_DIR — skipping CA generation"
fi

# ---------- Copy keys ----------
log "Installing keys into $KEY_DIR ..."
install -d -m 700 "$KEY_DIR"
cp "$CA_DIR/pki/ca.crt"                    "$KEY_DIR/"
cp "$CA_DIR/pki/issued/server.crt"         "$KEY_DIR/"
cp "$CA_DIR/pki/private/server.key"        "$KEY_DIR/"
cp "$CA_DIR/pki/crl.pem"                   "$KEY_DIR/"
cp "$CA_DIR/ta.key"                        "$KEY_DIR/"
chmod 600 "$KEY_DIR"/*
chown -R root:root "$KEY_DIR"

# ---------- Server config ----------
log "Writing server config..."
cat > "${OVPN_DIR}/server.conf" <<EOF
# --- Network ---
port $PORT
proto $PROTO
dev tun
topology subnet
server $VPN_NET $VPN_MASK
ifconfig-pool-persist /var/log/ovpn-ipp.txt

# --- Crypto ---
ca   $KEY_DIR/ca.crt
cert $KEY_DIR/server.crt
key  $KEY_DIR/server.key
crl-verify $KEY_DIR/crl.pem
tls-crypt $KEY_DIR/ta.key
dh none
ecdh-curve secp384r1
tls-version-min 1.2
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384
data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA512

# --- Routing / DNS ---
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
push "block-outside-dns"

# --- Hardening ---
user nobody
group nogroup
persist-key
persist-tun
remote-cert-tls client
keepalive 10 120
explicit-exit-notify 0

# --- Logging ---
status /var/log/openvpn-status.log
log-append /var/log/openvpn.log
verb 3
mute 20
EOF

# ---------- IP forwarding ----------
log "Enabling IP forwarding..."
cat > /etc/sysctl.d/99-openvpn.conf <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

# ---------- NAT (idempotent) ----------
log "Configuring NAT on $WAN_IFACE ..."
iptables -t nat -C POSTROUTING -s "$VPN_CIDR" -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$VPN_CIDR" -o "$WAN_IFACE" -j MASQUERADE

# Also allow forwarding (in case default policy is DROP)
iptables -C FORWARD -i tun0 -o "$WAN_IFACE" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i tun0 -o "$WAN_IFACE" -j ACCEPT
iptables -C FORWARD -i "$WAN_IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WAN_IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT

mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save >/dev/null 2>&1 || true

# ---------- Start service ----------
log "Enabling and starting OpenVPN..."
systemctl enable openvpn@server >/dev/null
systemctl restart openvpn@server

sleep 2
if ! systemctl is-active --quiet openvpn@server; then
    journalctl -u openvpn@server --no-pager -n 30
    die "OpenVPN failed to start — see log above"
fi
log "OpenVPN is running on $PROTO/$PORT"

# ---------- Build client .ovpn ----------
log "Building client config for '$VPN_USER' ..."
mkdir -p "$CLIENT_DIR"
OUT="$CLIENT_DIR/${VPN_USER}.ovpn"

{
cat <<EOF
client
dev tun
proto $PROTO
remote $SERVER_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name "server" name
tls-version-min 1.2
data-ciphers AES-256-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
auth SHA512
verb 3
EOF
echo "<ca>";       cat "$CA_DIR/pki/ca.crt";                    echo "</ca>"
echo "<cert>";     cat "$CA_DIR/pki/issued/${VPN_USER}.crt";    echo "</cert>"
echo "<key>";      cat "$CA_DIR/pki/private/${VPN_USER}.key";   echo "</key>"
echo "<tls-crypt>"; cat "$CA_DIR/ta.key";                       echo "</tls-crypt>"
} > "$OUT"

chmod 600 "$OUT"

# ---------- Final notes ----------
cat <<EOF

============================================================
  OpenVPN installation complete
============================================================
  Server IP      : $SERVER_IP
  Port / Proto   : $PORT / $PROTO
  Client config  : $OUT
  CA directory   : $CA_DIR   (back this up!)

  !!! Make sure your cloud firewall / Security Group allows:
       inbound  $PROTO/$PORT   from 0.0.0.0/0

  Add more clients:
    cd $CA_DIR
    EASYRSA_BATCH=1 ./easyrsa gen-req bob nopass
    EASYRSA_BATCH=1 ./easyrsa sign-req client bob
    # then rebuild a .ovpn using the same template above

  Revoke a client:
    cd $CA_DIR
    EASYRSA_BATCH=1 ./easyrsa revoke bob
    ./easyrsa gen-crl
    cp pki/crl.pem $KEY_DIR/crl.pem
    chmod 600 $KEY_DIR/crl.pem
    systemctl restart openvpn@server
============================================================
EOF

# ---------- Fetch the .ovpn (if run interactively) ----------
if [[ -t 1 ]]; then
    echo
    read -rp "Display client config now? [y/N] " ans
    [[ "${ans,,}" == "y" ]] && cat "$OUT"
fi