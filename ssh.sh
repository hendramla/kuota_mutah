#!/bin/bash

set -Eeuo pipefail

# ============================================================
# SSH PREMIUM INSTALLER
# Debian 12
#
# OpenSSH      : 22
# Dropbear     : 442
# SSH WS       : 80
# SSH WSS      : 443
# Squid        : 3128 / 8000 / 8080
# OpenVPN UDP  : 1194
# OpenVPN TCP  : 443 via SSLH
# BadVPN       : 7100 / 7200 / 7300 / 7400 / 7500
#
# Username : mashen
# Password : mashen
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Jalankan sebagai root."
    exit 1
fi

clear

echo "============================================================"
echo " SSH + WEBSOCKET + TLS + DROPBEAR + SQUID + OPENVPN + BADVPN"
echo " Debian 12"
echo "============================================================"
echo

DOMAIN=""

if [ "${1:-}" != "" ]; then
    DOMAIN="$1"
fi

if [ -z "$DOMAIN" ]; then

    if [ ! -e /dev/tty ]; then
        echo "ERROR: /dev/tty tidak tersedia."
        echo
        echo "Jalankan:"
        echo "bash install.sh domainanda.com"
        exit 1
    fi

    exec 3<>/dev/tty

    while [ -z "$DOMAIN" ]; do

        printf "Masukkan domain: " >&3
        IFS= read -r DOMAIN <&3 || true

        DOMAIN="$(
            printf '%s' "$DOMAIN" |
            tr -d '\r\n[:space:]'
        )"

        if [ -z "$DOMAIN" ]; then
            echo "Domain tidak boleh kosong." >&3
        fi

    done

fi

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN%.}"

if ! printf '%s' "$DOMAIN" \
    | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
then

    echo
    echo "ERROR: Domain tidak valid: $DOMAIN"
    exit 1

fi

USERNAME="mashen"
PASSWORD="mashen"

echo
echo "============================================================"
echo " KONFIGURASI"
echo "============================================================"
echo
echo "Domain   : $DOMAIN"
echo "Username : $USERNAME"
echo "Password : $PASSWORD"
echo

# ============================================================
# OS CHECK
# ============================================================

. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    echo "ERROR: Script hanya untuk Debian."
    exit 1
fi

echo "OS       : Debian ${VERSION_ID:-unknown}"

# ============================================================
# TIMEZONE
# ============================================================

timedatectl set-timezone Asia/Jakarta || true

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# HAPUS KONFLIK PAKET LAMA
# ============================================================

echo
echo "============================================================"
echo " MEMBERSIHKAN KONFLIK PAKET LAMA"
echo "============================================================"
echo

# Jangan install Node.js/npm di installer ini.
apt-mark unhold nodejs npm ufw \
    iptables-persistent \
    netfilter-persistent \
    2>/dev/null || true

dpkg --configure -a || true

# Buang paket Node/NPM yang menyebabkan konflik.
apt-get remove --purge -y \
    nodejs \
    npm \
    2>/dev/null || true

# Buang UFW + persistent firewall lama.
apt-get remove --purge -y \
    ufw \
    iptables-persistent \
    netfilter-persistent \
    2>/dev/null || true

apt-get autoremove -y || true

dpkg --configure -a || true

apt-get -f install -y || true

# ============================================================
# UPDATE
# ============================================================

apt-get update

# ============================================================
# INSTALL BASE PACKAGES
# ============================================================

echo
echo "============================================================"
echo " INSTALL PACKAGE"
echo "============================================================"
echo

apt-get install -y \
    curl \
    wget \
    git \
    unzip \
    zip \
    socat \
    ca-certificates \
    gnupg \
    openssl \
    nginx \
    certbot \
    jq \
    mtr-tiny \
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
    python3-websockets

# ============================================================
# CHECK PYTHON WEBSOCKETS
# ============================================================

python3 - <<'PY'
import websockets
print("Python WebSockets OK:", websockets.__version__)
PY

# ============================================================
# SSH USER
# ============================================================

echo
echo "============================================================"
echo " CREATE SSH USER"
echo "============================================================"
echo

if id "$USERNAME" >/dev/null 2>&1; then

    echo "$USERNAME:$PASSWORD" | chpasswd

else

    useradd \
        -m \
        -s /bin/bash \
        "$USERNAME"

    echo "$USERNAME:$PASSWORD" | chpasswd

fi

# ============================================================
# OPENSSH
# ============================================================

echo
echo "============================================================"
echo " OPENSSH PORT 22"
echo "============================================================"
echo

cp \
    /etc/ssh/sshd_config \
    "/etc/ssh/sshd_config.backup.$(date +%s)"

sed -i \
    '/^[[:space:]]*Port[[:space:]]/d' \
    /etc/ssh/sshd_config

sed -i \
    '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' \
    /etc/ssh/sshd_config

sed -i \
    '/^[[:space:]]*PermitRootLogin[[:space:]]/d' \
    /etc/ssh/sshd_config

sed -i \
    '/^[[:space:]]*UsePAM[[:space:]]/d' \
    /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<'EOF'

# ========================================
# SSH PREMIUM
# ========================================

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

sshd -t

systemctl enable ssh
systemctl restart ssh

# ============================================================
# DROPBEAR
# ============================================================

echo
echo "============================================================"
echo " DROPBEAR PORT 442"
echo "============================================================"
echo

cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=442
DROPBEAR_EXTRA_ARGS="-p 442"
DROPBEAR_BANNER="/etc/issue.net"
EOF

cat > /etc/issue.net <<EOF
========================================
 SSH PREMIUM
 Domain : $DOMAIN
========================================
EOF

systemctl enable dropbear
systemctl restart dropbear

# ============================================================
# PYTHON SSH WEBSOCKET SERVER
# ============================================================

echo
echo "============================================================"
echo " SSH WEBSOCKET PYTHON"
echo "============================================================"
echo

mkdir -p /opt/ssh-websocket

cat > /opt/ssh-websocket/server.py <<'PY'
#!/usr/bin/env python3

import asyncio
import websockets

WS_HOST = "127.0.0.1"
WS_PORT = 10080

SSH_HOST = "127.0.0.1"
SSH_PORT = 22


async def pipe_ws_to_tcp(websocket, writer):
    try:
        async for message in websocket:
            if isinstance(message, str):
                message = message.encode()

            writer.write(message)
            await writer.drain()

    except Exception:
        pass

    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def pipe_tcp_to_ws(websocket, reader):
    try:

        while True:

            data = await reader.read(65536)

            if not data:
                break

            await websocket.send(data)

    except Exception:
        pass

    finally:

        try:
            await websocket.close()
        except Exception:
            pass


async def handler(websocket, path):

    try:

        reader, writer = await asyncio.open_connection(
            SSH_HOST,
            SSH_PORT
        )

    except Exception:

        await websocket.close()
        return

    task1 = asyncio.create_task(
        pipe_ws_to_tcp(websocket, writer)
    )

    task2 = asyncio.create_task(
        pipe_tcp_to_ws(websocket, reader)
    )

    done, pending = await asyncio.wait(
        [task1, task2],
        return_when=asyncio.FIRST_COMPLETED
    )

    for task in pending:
        task.cancel()

    try:
        writer.close()
        await writer.wait_closed()
    except Exception:
        pass


async def process_request(path, request_headers):

    upgrade = request_headers.get("Upgrade", "").lower()

    if upgrade != "websocket":

        return (
            200,
            [
                ("Content-Type", "text/plain"),
                ("Connection", "close")
            ],
            b"SSH WebSocket Server\n"
        )

    return None


async def main():

    async with websockets.serve(
        handler,
        WS_HOST,
        WS_PORT,
        process_request=process_request,
        ping_interval=30,
        ping_timeout=30,
        max_size=None,
        compression=None
    ):

        print(
            f"SSH WebSocket listening on "
            f"{WS_HOST}:{WS_PORT}"
        )

        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
PY

chmod +x /opt/ssh-websocket/server.py

cat > /etc/systemd/system/ssh-websocket.service <<'EOF'
[Unit]
Description=SSH WebSocket Python
After=network-online.target ssh.service
Wants=network-online.target
Requires=ssh.service

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

systemctl enable ssh-websocket

systemctl restart ssh-websocket

sleep 2

if ! systemctl is-active --quiet ssh-websocket; then

    echo
    echo "SSH WebSocket gagal start."
    journalctl \
        -u ssh-websocket \
        --no-pager \
        -n 50

    exit 1

fi

# ============================================================
# FIREWALL IPTABLES
# ============================================================

echo
echo "============================================================"
echo " IPTABLES FIREWALL"
echo "============================================================"
echo

# Backup rules lama.
mkdir -p /root/iptables-backup

iptables-save \
    > "/root/iptables-backup/rules-$(date +%s).v4" \
    || true

# Tidak flush OUTPUT sehingga SSH installer tetap aman.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# ============================================================
# CERTBOT
# ============================================================

echo
echo "============================================================"
echo " SSL CERTIFICATE"
echo "============================================================"
echo

systemctl stop sslh 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

fuser -k 80/tcp 2>/dev/null || true

# Pastikan port 80 dan 443 boleh lewat.
iptables -I INPUT -p tcp --dport 22 -j ACCEPT \
    2>/dev/null || true

iptables -I INPUT -p tcp --dport 80 -j ACCEPT \
    2>/dev/null || true

iptables -I INPUT -p tcp --dport 443 -j ACCEPT \
    2>/dev/null || true

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --agree-tos \
        --non-interactive \
        --register-unsafely-without-email \
        -d "$DOMAIN"

fi

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then

    echo
    echo "============================================================"
    echo " SSL GAGAL"
    echo "============================================================"
    echo
    echo "Pastikan:"
    echo "1. $DOMAIN mengarah ke IP VPS."
    echo "2. Cloudflare sementara DNS Only."
    echo "3. Port TCP 80 terbuka."
    echo

    exit 1

fi

# ============================================================
# NGINX
# ============================================================

echo
echo "============================================================"
echo " NGINX WS + WSS"
echo "============================================================"
echo

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

rm -f /etc/nginx/conf.d/websocket-map.conf

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

        proxy_set_header X-Forwarded-For \
            \$proxy_add_x_forwarded_for;

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

    ssl_certificate \
        /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    ssl_certificate_key \
        /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:50m;

    ssl_session_timeout 1d;

    location / {

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;

        proxy_set_header X-Real-IP \$remote_addr;

        proxy_set_header X-Forwarded-For \
            \$proxy_add_x_forwarded_for;

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

nginx -t

systemctl enable nginx
systemctl restart nginx

# ============================================================
# SQUID
# ============================================================

echo
echo "============================================================"
echo " SQUID"
echo "============================================================"
echo

SQUID_AUTH="$(
    find /usr/lib \
        -type f \
        -name basic_ncsa_auth \
        2>/dev/null |
    head -1
)"

if [ -z "$SQUID_AUTH" ]; then

    echo "ERROR: basic_ncsa_auth tidak ditemukan."
    exit 1

fi

htpasswd \
    -bc \
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

via off

cache deny all

access_log /var/log/squid/access.log
EOF

squid -k parse

systemctl enable squid
systemctl restart squid

# ============================================================
# OPENVPN
# ============================================================

echo
echo "============================================================"
echo " OPENVPN"
echo "============================================================"
echo

mkdir -p /etc/openvpn/server

rm -rf /etc/openvpn/easy-rsa

make-cadir /etc/openvpn/easy-rsa

cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1

export EASYRSA_REQ_CN="SSH-VPN-CA"

./easyrsa init-pki

./easyrsa \
    --batch \
    build-ca \
    nopass

EASYRSA_CERT_EXPIRE=3650 \
./easyrsa \
    --batch \
    build-server-full \
    server \
    nopass

cp \
    pki/ca.crt \
    /etc/openvpn/server/ca.crt

cp \
    pki/issued/server.crt \
    /etc/openvpn/server/server.crt

cp \
    pki/private/server.key \
    /etc/openvpn/server/server.key

openvpn \
    --genkey \
    secret \
    /etc/openvpn/server/tls-crypt.key

PAM_PLUGIN="$(
    find /usr/lib \
        -type f \
        -name openvpn-plugin-auth-pam.so \
        2>/dev/null |
    head -1
)"

if [ -z "$PAM_PLUGIN" ]; then

    echo "ERROR: OpenVPN PAM Plugin tidak ditemukan."
    exit 1

fi

# ============================================================
# OPENVPN UDP 1194
# ============================================================

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

user nobody
group nogroup

push "redirect-gateway def1 bypass-dhcp"

push "dhcp-option DNS 1.1.1.1"

push "dhcp-option DNS 1.0.0.1"

status /var/log/openvpn-udp-status.log

verb 3
EOF

# ============================================================
# OPENVPN TCP BACKEND
# 443 -> SSLH -> 1195
# ============================================================

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

user nobody
group nogroup

push "redirect-gateway def1 bypass-dhcp"

push "dhcp-option DNS 1.1.1.1"

push "dhcp-option DNS 1.0.0.1"

status /var/log/openvpn-tcp-status.log

verb 3
EOF

systemctl daemon-reload

systemctl enable openvpn-server@udp1194
systemctl enable openvpn-server@tcp443

systemctl restart openvpn-server@udp1194
systemctl restart openvpn-server@tcp443

# ============================================================
# NETWORK TUNING
# ============================================================

echo
echo "============================================================"
echo " NETWORK TUNING"
echo "============================================================"
echo

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

net.ipv4.ip_local_port_range=1024 65535

fs.file-max=2097152
EOF

sysctl --system

# ============================================================
# NAT
# ============================================================

IFACE="$(
    ip -4 route show default |
    awk '/default/ {print $5; exit}'
)"

if [ -z "$IFACE" ]; then

    echo "ERROR: Interface internet tidak ditemukan."
    exit 1

fi

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
    -d 10.8.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -d 10.8.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
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
    -d 10.9.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -d 10.9.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

# ============================================================
# ALLOW PORTS
# ============================================================

for PORT in \
    22 \
    80 \
    443 \
    442 \
    3128 \
    8000 \
    8080
do

    iptables \
        -C INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT \
        2>/dev/null || \
    iptables \
        -A INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT

done

iptables \
    -C INPUT \
    -p udp \
    --dport 1194 \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A INPUT \
    -p udp \
    --dport 1194 \
    -j ACCEPT

# UDP CUSTOM 1-65535
iptables \
    -C INPUT \
    -p udp \
    --dport 1:65535 \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A INPUT \
    -p udp \
    --dport 1:65535 \
    -j ACCEPT

# ============================================================
# SAVE IPTABLES TANPA netfilter-persistent
# ============================================================

mkdir -p /etc/iptables-custom

iptables-save \
    > /etc/iptables-custom/rules.v4

cat > /etc/systemd/system/iptables-custom.service <<'EOF'
[Unit]
Description=Restore SSH VPN iptables rules
After=network-pre.target
Before=network.target

[Service]
Type=oneshot

ExecStart=/sbin/iptables-restore /etc/iptables-custom/rules.v4

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable iptables-custom.service

# ============================================================
# SSLH 443
# ============================================================

echo
echo "============================================================"
echo " SSLH PORT 443"
echo "============================================================"
echo

systemctl stop sslh 2>/dev/null || true

cat > /etc/default/sslh <<'EOF'
RUN=yes

DAEMON=/usr/sbin/sslh

DAEMON_OPTS="--user sslh --listen 0.0.0.0:443 --openvpn 127.0.0.1:1195 --tls 127.0.0.1:8443 --timeout 3"
EOF

systemctl daemon-reload

systemctl enable sslh

systemctl restart sslh

# ============================================================
# BADVPN
# ============================================================

echo
echo "============================================================"
echo " BADVPN UDPGW"
echo "============================================================"
echo

rm -rf /tmp/badvpn-src

git clone \
    --depth=1 \
    https://github.com/ambrop72/badvpn.git \
    /tmp/badvpn-src

cd /tmp/badvpn-src

rm -rf build

mkdir -p build

cd build

cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

make -j"$(nproc)"

BADVPN_BIN="$(
    find . \
        -type f \
        -name badvpn-udpgw |
    head -1
)"

if [ -z "$BADVPN_BIN" ]; then

    echo "ERROR: Build BadVPN gagal."
    exit 1

fi

install \
    -m 755 \
    "$BADVPN_BIN" \
    /usr/local/bin/badvpn-udpgw

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
Wants=network-online.target

[Service]
Type=simple

ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 0.0.0.0:$PORT --max-clients 1000 --max-connections-for-client 20

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

    systemctl enable "badvpn-${PORT}.service"

    systemctl restart "badvpn-${PORT}.service"

done

# ============================================================
# OPENVPN CLIENT CONFIG
# ============================================================

echo
echo "============================================================"
echo " CREATE OVPN CONFIG"
echo "============================================================"
echo

mkdir -p /root/ovpn

CA_CERT="$(
    cat /etc/openvpn/server/ca.crt
)"

TLS_CRYPT="$(
    cat /etc/openvpn/server/tls-crypt.key
)"

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
# CERTBOT RENEW HOOK
# ============================================================

mkdir -p \
    /etc/letsencrypt/renewal-hooks/deploy

cat > \
/etc/letsencrypt/renewal-hooks/deploy/restart-ssh-services.sh <<'EOF'
#!/bin/bash

systemctl restart nginx

systemctl restart sslh
EOF

chmod +x \
    /etc/letsencrypt/renewal-hooks/deploy/restart-ssh-services.sh

systemctl enable certbot.timer 2>/dev/null || true

systemctl restart certbot.timer 2>/dev/null || true

# ============================================================
# RESTART SERVICES
# ============================================================

echo
echo "============================================================"
echo " RESTART SERVICES"
echo "============================================================"
echo

systemctl daemon-reload

systemctl restart ssh

systemctl restart dropbear

systemctl restart ssh-websocket

systemctl restart nginx

systemctl restart squid

systemctl restart openvpn-server@udp1194

systemctl restart openvpn-server@tcp443

systemctl restart sslh

for PORT in \
    7100 \
    7200 \
    7300 \
    7400 \
    7500
do

    systemctl restart \
        "badvpn-${PORT}.service"

done

iptables-save \
    > /etc/iptables-custom/rules.v4

sleep 3

# ============================================================
# IP
# ============================================================

IP="$(
    curl \
        -4 \
        -s \
        --max-time 10 \
        https://api.ipify.org \
        2>/dev/null \
        || true
)"

if [ -z "$IP" ]; then

    IP="$(
        hostname -I |
        awk '{print $1}'
    )"

fi

# ============================================================
# FINAL STATUS
# ============================================================

clear

echo "============================================================"
echo " INSTALL SSH SELESAI"
echo "============================================================"
echo

echo "Host IP              : $IP"

echo "Host Domain          : $DOMAIN"

echo
echo "============================================================"
echo " SSH"
echo "============================================================"
echo

echo "Username SSH         : $USERNAME"

echo "Password SSH         : $PASSWORD"

echo
echo "OpenSSH              : 22"

echo "Dropbear             : 442"

echo "SSH WS Non TLS       : 80"

echo "SSH WSS TLS          : 443"

echo
echo "============================================================"
echo " SQUID"
echo "============================================================"
echo

echo "Squid Host           : $DOMAIN"

echo "Squid Port           : 8080 / 8000 / 3128"

echo "Squid Username       : $USERNAME"

echo "Squid Password       : $PASSWORD"

echo
echo "============================================================"
echo " BADVPN UDPGW"
echo "============================================================"
echo

echo "BadVPN               : 7100"

echo "                       7200"

echo "                       7300"

echo "                       7400"

echo "                       7500"

echo
echo "============================================================"
echo " OPENVPN"
echo "============================================================"
echo

echo "OpenVPN UDP          : 1194"

echo "OpenVPN TCP          : 443"

echo
echo "Username             : $USERNAME"

echo "Password             : $PASSWORD"

echo
echo "OVPN UDP Config:"

echo "/root/ovpn/openvpn-1194.ovpn"

echo
echo "OVPN TCP Config:"

echo "/root/ovpn/openvpn-443.ovpn"

echo
echo "============================================================"
echo " PAYLOAD WEBSOCKET NON TLS"
echo "============================================================"
echo

echo "GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "Remote Proxy: $DOMAIN:80"

echo
echo "============================================================"
echo " PAYLOAD WEBSOCKET TLS"
echo "============================================================"
echo

echo "GET wss://$DOMAIN/ HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "SNI          : $DOMAIN"

echo "Remote Proxy : $DOMAIN:443"

echo
echo "============================================================"
echo " UDP CUSTOM"
echo "============================================================"
echo

echo "UDP Custom           : 1-65535"

echo
echo "============================================================"
echo " LISTEN PORTS"
echo "============================================================"
echo

ss -lntup |
grep -E \
':(22|80|443|442|1194|1195|3128|8000|8080|7100|7200|7300|7400|7500|8443|10080)\b' \
|| true

echo
echo "============================================================"
echo " SERVICE STATUS"
echo "============================================================"
echo

SERVICES=(
    ssh
    dropbear
    ssh-websocket
    nginx
    squid
    sslh
    openvpn-server@udp1194
    openvpn-server@tcp443
    badvpn-7100
    badvpn-7200
    badvpn-7300
    badvpn-7400
    badvpn-7500
)

for SERVICE in "${SERVICES[@]}"
do

    printf "%-32s : " "$SERVICE"

    if systemctl is-active \
        --quiet \
        "$SERVICE"
    then

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
echo "============================================================"
echo " SELESAI"
echo "============================================================"
echo
