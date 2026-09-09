#!/bin/bash

set -uo pipefail

# ============================================================
# SSH + WS + WSS + DROPBEAR + SQUID + OPENVPN + BADVPN
# Debian 12
# ============================================================

USERNAME="mashen"
PASSWORD="mashen"

fail() {
    echo
    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo "$1"
    echo
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
    echo
}

if [ "$(id -u)" -ne 0 ]; then
    fail "Jalankan script sebagai root."
fi

clear

section "SSH + WEBSOCKET + TLS + DROPBEAR + SQUID + OPENVPN + BADVPN"

echo "Debian 12"
echo

# ============================================================
# INPUT DOMAIN
# ============================================================

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then

    if [ ! -e /dev/tty ]; then
        fail "Gunakan: bash install.sh domainanda.com"
    fi

    exec 3<>/dev/tty

    while [ -z "$DOMAIN" ]; do

        printf "Masukkan domain: " >&3

        IFS= read -r DOMAIN <&3 || true

        DOMAIN="$(printf '%s' "$DOMAIN" | tr -d '\r\n[:space:]')"

        if [ -z "$DOMAIN" ]; then
            echo "Domain tidak boleh kosong." >&3
        fi

    done
fi

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN%.}"

if ! echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
    fail "Domain tidak valid: $DOMAIN"
fi

echo
echo "Domain   : $DOMAIN"
echo "Username : $USERNAME"
echo "Password : $PASSWORD"

# ============================================================
# OS CHECK
# ============================================================

[ -f /etc/os-release ] || fail "/etc/os-release tidak ditemukan."

. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    fail "Script hanya untuk Debian."
fi

timedatectl set-timezone Asia/Jakarta || true

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# FIX APT
# ============================================================

section "FIX APT"

apt-mark unhold \
    nodejs \
    npm \
    ufw \
    iptables-persistent \
    netfilter-persistent \
    2>/dev/null || true

dpkg --configure -a || true

apt-get remove --purge -y \
    nodejs \
    npm \
    ufw \
    iptables-persistent \
    netfilter-persistent \
    2>/dev/null || true

apt-get autoremove -y || true

apt-get -f install -y || true

apt-get update || fail "apt-get update gagal."

# ============================================================
# PACKAGES
# ============================================================

section "INSTALL PACKAGES"

apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    zip \
    socat \
    ca-certificates \
    openssl \
    nginx \
    certbot \
    jq \
    dnsutils \
    iproute2 \
    net-tools \
    procps \
    openssh-server \
    dropbear \
    squid \
    sslh \
    openvpn \
    easy-rsa \
    iptables \
    build-essential \
    cmake \
    apache2-utils \
    python3 \
    python3-websockets \
    || fail "Install package gagal."

# ============================================================
# SSH USER
# ============================================================

section "SSH USER"

if id "$USERNAME" >/dev/null 2>&1; then
    echo "$USERNAME:$PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USERNAME" || fail "Gagal membuat user."
    echo "$USERNAME:$PASSWORD" | chpasswd
fi

# ============================================================
# OPENSSH
# ============================================================

section "OPENSSH PORT 22"

cp /etc/ssh/sshd_config \
   "/etc/ssh/sshd_config.backup.$(date +%s)" \
   2>/dev/null || true

sed -i '/^[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*UsePAM[[:space:]]/d' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<'EOF'

Port 22
PasswordAuthentication yes
UsePAM yes
PermitRootLogin prohibit-password

TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3

MaxSessions 1000
MaxStartups 1000:30:2000
EOF

sshd -t || fail "Konfigurasi OpenSSH error."

systemctl enable ssh >/dev/null 2>&1 || true

# Tidak perlu restart bila ssh sudah aktif.
# Reload lebih aman agar sesi installer tidak terputus.
systemctl reload ssh || systemctl restart ssh || fail "SSH gagal."

# ============================================================
# DROPBEAR
# ============================================================

section "DROPBEAR PORT 442"

cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=442
DROPBEAR_EXTRA_ARGS="-p 442"
DROPBEAR_BANNER="/etc/issue.net"
EOF

cat > /etc/issue.net <<EOF
========================================
 SSH PREMIUM SERVER
 Domain : $DOMAIN
========================================
EOF

systemctl enable dropbear >/dev/null 2>&1 || true
systemctl restart dropbear || fail "Dropbear gagal start."

# ============================================================
# PYTHON WEBSOCKET
# ============================================================

section "SSH WEBSOCKET"

python3 -c 'import websockets' \
    || fail "python3-websockets tidak tersedia."

mkdir -p /opt/ssh-websocket

cat > /opt/ssh-websocket/server.py <<'PY'
#!/usr/bin/env python3

import asyncio
import websockets


async def ws_to_ssh(ws, writer):
    try:
        async for message in ws:
            if isinstance(message, str):
                message = message.encode()

            writer.write(message)
            await writer.drain()

    except Exception:
        pass


async def ssh_to_ws(ws, reader):
    try:
        while True:
            data = await reader.read(65536)

            if not data:
                break

            await ws.send(data)

    except Exception:
        pass


async def handler(ws, path):
    try:
        reader, writer = await asyncio.open_connection(
            "127.0.0.1",
            22
        )
    except Exception:
        await ws.close()
        return

    a = asyncio.create_task(
        ws_to_ssh(ws, writer)
    )

    b = asyncio.create_task(
        ssh_to_ws(ws, reader)
    )

    done, pending = await asyncio.wait(
        [a, b],
        return_when=asyncio.FIRST_COMPLETED
    )

    for task in pending:
        task.cancel()

    try:
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


async def main():

    async with websockets.serve(
        handler,
        "127.0.0.1",
        10080,
        ping_interval=30,
        ping_timeout=30,
        max_size=None,
        compression=None
    ):

        print("SSH WebSocket listening 127.0.0.1:10080")

        await asyncio.Future()


asyncio.run(main())
PY

chmod +x /opt/ssh-websocket/server.py

cat > /etc/systemd/system/ssh-websocket.service <<'EOF'
[Unit]
Description=SSH WebSocket
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=root

ExecStart=/usr/bin/python3 /opt/ssh-websocket/server.py

Restart=always
RestartSec=2

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable ssh-websocket >/dev/null 2>&1 || true

systemctl restart ssh-websocket || true

sleep 2

if ! systemctl is-active --quiet ssh-websocket; then

    journalctl \
        -u ssh-websocket \
        -n 30 \
        --no-pager

    fail "SSH WebSocket gagal."

fi

# ============================================================
# CERTBOT
# ============================================================

section "SSL CERTIFICATE"

systemctl stop sslh 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --agree-tos \
        --non-interactive \
        --register-unsafely-without-email \
        -d "$DOMAIN"

    CERTBOT_RESULT=$?

    if [ "$CERTBOT_RESULT" -ne 0 ]; then
        fail "Certbot gagal. Pastikan domain mengarah ke VPS, port 80 terbuka, dan Cloudflare DNS Only."
    fi

fi

[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] \
    || fail "Certificate tidak ditemukan."

# ============================================================
# NGINX
# ============================================================

section "NGINX WS + WSS"

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

cat > /etc/nginx/conf.d/websocket-map.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF

cat > /etc/nginx/sites-available/ssh-websocket <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    location / {
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_pass http://127.0.0.1:10080;
    }
}

server {
    listen 127.0.0.1:8443 ssl;

    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    location / {
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_pass http://127.0.0.1:10080;
    }
}
EOF

ln -sf \
    /etc/nginx/sites-available/ssh-websocket \
    /etc/nginx/sites-enabled/ssh-websocket

cat > /etc/nginx/conf.d/ssh-tuning.conf <<'EOF'
client_max_body_size 100m;

proxy_connect_timeout 60s;
proxy_send_timeout 86400s;
proxy_read_timeout 86400s;

keepalive_timeout 75s;
keepalive_requests 100000;
EOF

nginx -t || fail "nginx -t gagal."

systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx || fail "Nginx gagal start."

# ============================================================
# SQUID
# ============================================================

section "SQUID"

SQUID_AUTH="$(find /usr/lib \
    -type f \
    -name basic_ncsa_auth \
    2>/dev/null \
    | head -1)"

[ -n "$SQUID_AUTH" ] \
    || fail "basic_ncsa_auth tidak ditemukan."

htpasswd -bc \
    /etc/squid/passwd \
    "$USERNAME" \
    "$PASSWORD"

cat > /etc/squid/squid.conf <<EOF
http_port 3128
http_port 8000
http_port 8080

visible_hostname $DOMAIN

auth_param basic program $SQUID_AUTH /etc/squid/passwd
auth_param basic realm SSH-PROXY
auth_param basic credentialsttl 24 hours

acl authenticated proxy_auth REQUIRED

http_access allow authenticated
http_access deny all

forwarded_for delete

via on

cache deny all

access_log /var/log/squid/access.log
EOF

if ! squid -k parse; then
    fail "Konfigurasi Squid gagal."
fi

systemctl enable squid >/dev/null 2>&1 || true

if ! systemctl restart squid; then

    journalctl \
        -u squid \
        -n 30 \
        --no-pager

    fail "Squid gagal start."

fi

echo
echo "SQUID BERHASIL"
echo

# ============================================================
# EASY-RSA
# ============================================================

section "OPENVPN EASY-RSA"

EASYRSA="/usr/share/easy-rsa/easyrsa"

[ -x "$EASYRSA" ] \
    || fail "EasyRSA tidak ditemukan di $EASYRSA"

rm -rf /etc/openvpn/easy-rsa

mkdir -p /etc/openvpn/easy-rsa
mkdir -p /etc/openvpn/server

cd /etc/openvpn/easy-rsa \
    || fail "Tidak bisa membuka folder EasyRSA."

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="SSH-VPN-CA"
export EASYRSA_PKI="/etc/openvpn/easy-rsa/pki"

"$EASYRSA" init-pki \
    || fail "EasyRSA init-pki gagal."

"$EASYRSA" \
    --batch \
    build-ca \
    nopass \
    || fail "Build OpenVPN CA gagal."

EASYRSA_CERT_EXPIRE=3650 \
"$EASYRSA" \
    --batch \
    build-server-full \
    server \
    nopass \
    || fail "Build OpenVPN server certificate gagal."

cp \
    "$EASYRSA_PKI/ca.crt" \
    /etc/openvpn/server/ca.crt \
    || fail "Copy ca.crt gagal."

cp \
    "$EASYRSA_PKI/issued/server.crt" \
    /etc/openvpn/server/server.crt \
    || fail "Copy server.crt gagal."

cp \
    "$EASYRSA_PKI/private/server.key" \
    /etc/openvpn/server/server.key \
    || fail "Copy server.key gagal."

openvpn \
    --genkey secret \
    /etc/openvpn/server/tls-crypt.key \
    || fail "Generate tls-crypt gagal."

PAM_PLUGIN="$(find /usr/lib \
    -type f \
    -name openvpn-plugin-auth-pam.so \
    2>/dev/null \
    | head -1)"

[ -n "$PAM_PLUGIN" ] \
    || fail "OpenVPN PAM plugin tidak ditemukan."

echo "PAM Plugin: $PAM_PLUGIN"

# ============================================================
# OPENVPN UDP
# ============================================================

section "OPENVPN UDP 1194"

cat > /etc/openvpn/server/udp1194.conf <<EOF
port 1194
proto udp

dev tun0

topology subnet
server 10.8.0.0 255.255.255.0

ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key

dh none

tls-crypt /etc/openvpn/server/tls-crypt.key

verify-client-cert none
username-as-common-name

plugin $PAM_PLUGIN login

tls-version-min 1.2

auth SHA256

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

keepalive 10 120

persist-key
persist-tun

push "redirect-gateway def1 bypass-dhcp"

push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

verb 3
EOF

# ============================================================
# OPENVPN TCP 443 BACKEND
# ============================================================

section "OPENVPN TCP 443"

cat > /etc/openvpn/server/tcp443.conf <<EOF
local 127.0.0.1

port 1195

proto tcp-server

dev tun1

topology subnet
server 10.9.0.0 255.255.255.0

ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key

dh none

tls-crypt /etc/openvpn/server/tls-crypt.key

verify-client-cert none
username-as-common-name

plugin $PAM_PLUGIN login

tls-version-min 1.2

auth SHA256

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

keepalive 10 120

persist-key
persist-tun

push "redirect-gateway def1 bypass-dhcp"

push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

verb 3
EOF

systemctl daemon-reload

systemctl enable openvpn-server@udp1194 >/dev/null 2>&1 || true
systemctl enable openvpn-server@tcp443 >/dev/null 2>&1 || true

if ! systemctl restart openvpn-server@udp1194; then

    journalctl \
        -u openvpn-server@udp1194 \
        -n 40 \
        --no-pager

    fail "OpenVPN UDP 1194 gagal."

fi

if ! systemctl restart openvpn-server@tcp443; then

    journalctl \
        -u openvpn-server@tcp443 \
        -n 40 \
        --no-pager

    fail "OpenVPN TCP backend gagal."

fi

# ============================================================
# SYSCTL
# ============================================================

section "NETWORK TUNING"

cat > /etc/sysctl.d/99-ssh-vpn.conf <<'EOF'
net.ipv4.ip_forward=1

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=65535

net.ipv4.tcp_max_syn_backlog=65535

net.ipv4.tcp_fin_timeout=15

net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

fs.file-max=2097152
EOF

sysctl --system >/dev/null \
    || fail "sysctl gagal."

# ============================================================
# NAT
# ============================================================

section "IPTABLES NAT"

IFACE="$(ip -4 route show default \
    | awk '/default/ {print $5; exit}')"

[ -n "$IFACE" ] \
    || fail "Interface internet tidak ditemukan."

iptables -t nat \
    -C POSTROUTING \
    -s 10.8.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE \
    2>/dev/null || \
iptables -t nat \
    -A POSTROUTING \
    -s 10.8.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE

iptables -t nat \
    -C POSTROUTING \
    -s 10.9.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE \
    2>/dev/null || \
iptables -t nat \
    -A POSTROUTING \
    -s 10.9.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE

iptables \
    -C FORWARD \
    -s 10.8.0.0/24 \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -s 10.8.0.0/24 \
    -j ACCEPT

iptables \
    -C FORWARD \
    -s 10.9.0.0/24 \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -s 10.9.0.0/24 \
    -j ACCEPT

iptables \
    -C FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

# ============================================================
# SAVE IPTABLES
# ============================================================

mkdir -p /etc/iptables-custom

iptables-save > /etc/iptables-custom/rules.v4

cat > /etc/systemd/system/iptables-custom.service <<'EOF'
[Unit]
Description=Restore custom iptables
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables-custom/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-custom.service >/dev/null 2>&1 || true

# ============================================================
# SSLH
# ============================================================

section "SSLH PORT 443"

systemctl stop sslh 2>/dev/null || true

SSLH_BIN="$(command -v sslh || true)"

if [ -z "$SSLH_BIN" ]; then
    SSLH_BIN="$(command -v sslh-fork || true)"
fi

[ -n "$SSLH_BIN" ] \
    || fail "Binary sslh tidak ditemukan."

cat > /etc/default/sslh <<EOF
RUN=yes

DAEMON=$SSLH_BIN

DAEMON_OPTS="--user sslh --listen 0.0.0.0:443 --openvpn 127.0.0.1:1195 --tls 127.0.0.1:8443 --timeout 3"
EOF

systemctl daemon-reload
systemctl enable sslh >/dev/null 2>&1 || true

if ! systemctl restart sslh; then

    journalctl \
        -u sslh \
        -n 40 \
        --no-pager

    fail "SSLH gagal start."

fi

# ============================================================
# BADVPN
# ============================================================

section "BADVPN"

rm -rf /tmp/badvpn-src

git clone \
    --depth=1 \
    https://github.com/ambrop72/badvpn.git \
    /tmp/badvpn-src \
    || fail "Clone BadVPN gagal."

mkdir -p /tmp/badvpn-src/build

cd /tmp/badvpn-src/build \
    || fail "Folder BadVPN gagal."

cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    || fail "CMake BadVPN gagal."

make -j"$(nproc)" \
    || fail "Compile BadVPN gagal."

BADVPN_BIN="$(find . \
    -type f \
    -name badvpn-udpgw \
    | head -1)"

[ -n "$BADVPN_BIN" ] \
    || fail "badvpn-udpgw tidak ditemukan."

install \
    -m 755 \
    "$BADVPN_BIN" \
    /usr/local/bin/badvpn-udpgw \
    || fail "Install BadVPN gagal."

for PORT in \
    7100 \
    7200 \
    7300 \
    7400 \
    7500
do

cat > "/etc/systemd/system/badvpn-${PORT}.service" <<EOF
[Unit]
Description=BadVPN UDPGW $PORT
After=network-online.target

[Service]
Type=simple

ExecStart=/usr/local/bin/badvpn-udpgw \
--listen-addr 0.0.0.0:$PORT \
--max-clients 1000 \
--max-connections-for-client 20

Restart=always
RestartSec=2

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

done

systemctl daemon-reload

for PORT in \
    7100 \
    7200 \
    7300 \
    7400 \
    7500
do

    systemctl enable \
        "badvpn-${PORT}.service" \
        >/dev/null 2>&1 || true

    systemctl restart \
        "badvpn-${PORT}.service" \
        || fail "BadVPN port $PORT gagal."

done

# ============================================================
# OVPN CLIENT
# ============================================================

section "GENERATE OVPN"

mkdir -p /root/ovpn

CA_CERT="$(cat /etc/openvpn/server/ca.crt)"
TLS_CRYPT="$(cat /etc/openvpn/server/tls-crypt.key)"

cat > /root/ovpn/openvpn-1194.ovpn <<EOF
client
dev tun

proto udp

remote $DOMAIN 1194

resolv-retry infinite
nobind

persist-key
persist-tun

remote-cert-tls server

auth-user-pass
auth-nocache

auth SHA256

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

verb 3

<ca>
$CA_CERT
</ca>

<tls-crypt>
$TLS_CRYPT
</tls-crypt>
EOF

cat > /root/ovpn/openvpn-443.ovpn <<EOF
client
dev tun

proto tcp-client

remote $DOMAIN 443

resolv-retry infinite
nobind

persist-key
persist-tun

remote-cert-tls server

auth-user-pass
auth-nocache

auth SHA256

data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

verb 3

<ca>
$CA_CERT
</ca>

<tls-crypt>
$TLS_CRYPT
</tls-crypt>
EOF

chmod 600 /root/ovpn/*.ovpn

# ============================================================
# CERTBOT AUTO RENEW
# ============================================================

mkdir -p \
    /etc/letsencrypt/renewal-hooks/deploy

cat > \
/etc/letsencrypt/renewal-hooks/deploy/restart-ssh.sh <<'EOF'
#!/bin/bash
systemctl restart nginx
systemctl restart sslh
EOF

chmod +x \
    /etc/letsencrypt/renewal-hooks/deploy/restart-ssh.sh

systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl restart certbot.timer >/dev/null 2>&1 || true

# ============================================================
# SAVE FINAL IPTABLES
# ============================================================

iptables-save > /etc/iptables-custom/rules.v4

# ============================================================
# FINAL
# ============================================================

IP="$(curl -4 \
    -s \
    --max-time 10 \
    https://api.ipify.org \
    2>/dev/null || true)"

if [ -z "$IP" ]; then
    IP="$(hostname -I | awk '{print $1}')"
fi

clear

section "INSTALL SELESAI"

echo "Host IP              : $IP"
echo "Host Domain          : $DOMAIN"
echo
echo "Username SSH         : $USERNAME"
echo "Password SSH         : $PASSWORD"
echo
echo "OpenSSH              : 22"
echo "Dropbear             : 442"
echo "SSH WS               : 80"
echo "SSH WSS              : 443"
echo
echo "Squid                : 3128 / 8000 / 8080"
echo
echo "OpenVPN UDP          : 1194"
echo "OpenVPN TCP          : 443"
echo
echo "BadVPN               : 7100 / 7200 / 7300 / 7400 / 7500"
echo
echo "OVPN UDP             : /root/ovpn/openvpn-1194.ovpn"
echo "OVPN TCP             : /root/ovpn/openvpn-443.ovpn"

echo
echo "PAYLOAD WS:"
echo
echo "GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "PAYLOAD WSS:"
echo
echo "GET wss://$DOMAIN/ HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "SNI: $DOMAIN"

section "LISTEN PORT"

ss -lntup |
grep -E \
':(22|80|443|442|1194|1195|3128|8000|8080|7100|7200|7300|7400|7500|8443|10080)\b' \
|| true

section "SERVICE STATUS"

for SERVICE in \
    ssh \
    dropbear \
    ssh-websocket \
    nginx \
    squid \
    sslh \
    openvpn-server@udp1194 \
    openvpn-server@tcp443 \
    badvpn-7100 \
    badvpn-7200 \
    badvpn-7300 \
    badvpn-7400 \
    badvpn-7500
do

    printf "%-32s : " "$SERVICE"

    if systemctl is-active --quiet "$SERVICE"; then
        echo "ACTIVE"
    else
        echo "FAILED"
    fi

done

echo
echo "============================================================"
echo " SSH LOGIN"
echo "============================================================"
echo
echo "ssh $USERNAME@$DOMAIN -p 22"
echo
echo "Username : $USERNAME"
echo "Password : $PASSWORD"
echo
