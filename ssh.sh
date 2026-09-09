#!/bin/bash

set -Eeuo pipefail

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

if ! printf '%s' "$DOMAIN" | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
    echo "ERROR: Format domain tidak valid: $DOMAIN"
    exit 1
fi

USERNAME="mashen"
PASSWORD="mashen"

echo
echo "Domain   : $DOMAIN"
echo "Username : $USERNAME"
echo "Password : $PASSWORD"
echo

# ============================================================
# OS
# ============================================================

. /etc/os-release

if [ "${ID:-}" != "debian" ]; then
    echo "ERROR: Script dibuat untuk Debian."
    exit 1
fi

timedatectl set-timezone Asia/Jakarta || true

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# CLEAN BROKEN PACKAGE STATE
# ============================================================

echo "============================================================"
echo " FIX PACKAGE STATE"
echo "============================================================"

dpkg --configure -a || true

apt-get -f install -y || true

# Hapus paket yang menyebabkan konflik bila ada.
apt-get remove -y \
    npm \
    nodejs \
    iptables-persistent \
    netfilter-persistent \
    2>/dev/null || true

apt-get autoremove -y || true

apt-get update

# ============================================================
# BASE PACKAGES
# ============================================================

echo "============================================================"
echo " INSTALL BASE PACKAGES"
echo "============================================================"

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
    ufw \
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
    apache2-utils

# ============================================================
# NODE.JS 24 + NPM
# npm SUDAH TERMASUK DI NODE.JS NODESOURCE
# ============================================================

echo "============================================================"
echo " INSTALL NODE.JS"
echo "============================================================"

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

node -v
npm -v

# ============================================================
# SSH USER
# ============================================================

if id "$USERNAME" >/dev/null 2>&1; then
    echo "$USERNAME:$PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
fi

# ============================================================
# OPENSSH
# ============================================================

cp /etc/ssh/sshd_config \
    "/etc/ssh/sshd_config.backup.$(date +%s)"

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

sshd -t

systemctl enable ssh
systemctl restart ssh

# ============================================================
# DROPBEAR
# ============================================================

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

systemctl enable dropbear
systemctl restart dropbear

# ============================================================
# SSH WEBSOCKET
# ============================================================

mkdir -p /opt/ssh-websocket

cd /opt/ssh-websocket

cat > package.json <<'EOF'
{
  "name": "ssh-websocket",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "ws": "^8.18.0"
  }
}
EOF

npm install --omit=dev --no-audit --no-fund

cat > /opt/ssh-websocket/server.js <<'EOF'
'use strict';

const http = require('http');
const net = require('net');
const WebSocket = require('ws');

const server = http.createServer((req, res) => {
    res.writeHead(200, {
        'Content-Type': 'text/plain'
    });

    res.end('SSH WebSocket Server\n');
});

const wss = new WebSocket.Server({
    noServer: true,
    perMessageDeflate: false
});

server.on('upgrade', (request, socket, head) => {
    wss.handleUpgrade(request, socket, head, (ws) => {
        wss.emit('connection', ws, request);
    });
});

wss.on('connection', (ws) => {
    const ssh = net.connect({
        host: '127.0.0.1',
        port: 22
    });

    let closed = false;

    const closeAll = () => {
        if (closed) return;

        closed = true;

        try {
            ssh.destroy();
        } catch (_) {}

        try {
            ws.terminate();
        } catch (_) {}
    };

    ws.on('message', (message) => {
        if (!ssh.destroyed) {
            ssh.write(Buffer.from(message));
        }
    });

    ssh.on('data', (data) => {
        if (ws.readyState === WebSocket.OPEN) {
            ws.send(data);
        }
    });

    ws.on('close', closeAll);
    ws.on('error', closeAll);

    ssh.on('close', closeAll);
    ssh.on('error', closeAll);
});

server.listen(10080, '127.0.0.1', () => {
    console.log('SSH WebSocket listening on 127.0.0.1:10080');
});
EOF

cat > /etc/systemd/system/ssh-websocket.service <<'EOF'
[Unit]
Description=SSH WebSocket Tunnel
After=network-online.target ssh.service
Wants=network-online.target
Requires=ssh.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ssh-websocket
ExecStart=/usr/bin/node /opt/ssh-websocket/server.js
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh-websocket
systemctl restart ssh-websocket

# ============================================================
# CERTBOT
# ============================================================

systemctl stop sslh 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

fuser -k 80/tcp 2>/dev/null || true

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 80/tcp >/dev/null 2>&1 || true

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
    echo "SSL gagal."
    echo "Pastikan domain mengarah ke IP VPS dan Cloudflare DNS Only."
    exit 1
fi

# ============================================================
# NGINX
# ============================================================

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

nginx -t

systemctl enable nginx
systemctl restart nginx

# ============================================================
# SQUID
# ============================================================

SQUID_AUTH="$(find /usr/lib \
    -type f \
    -name basic_ncsa_auth \
    2>/dev/null \
    | head -1)"

if [ -z "$SQUID_AUTH" ]; then
    echo "ERROR: basic_ncsa_auth tidak ditemukan."
    exit 1
fi

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
via off

cache deny all

access_log /var/log/squid/access.log
EOF

squid -k parse

systemctl enable squid
systemctl restart squid

# ============================================================
# OPENVPN PKI
# ============================================================

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

cp pki/ca.crt \
    /etc/openvpn/server/ca.crt

cp pki/issued/server.crt \
    /etc/openvpn/server/server.crt

cp pki/private/server.key \
    /etc/openvpn/server/server.key

openvpn \
    --genkey secret \
    /etc/openvpn/server/tls-crypt.key

PAM_PLUGIN="$(find /usr/lib \
    -type f \
    -name openvpn-plugin-auth-pam.so \
    2>/dev/null \
    | head -1)"

if [ -z "$PAM_PLUGIN" ]; then
    echo "ERROR: OpenVPN PAM plugin tidak ditemukan."
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
# SYSCTL
# ============================================================

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

IFACE="$(ip -4 route show default \
    | awk '/default/ {print $5; exit}')"

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
    -s 10.9.0.0/24 \
    -j ACCEPT \
    2>/dev/null || \
iptables \
    -A FORWARD \
    -s 10.9.0.0/24 \
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
# SAVE IPTABLES SENDIRI
# TANPA iptables-persistent
# ============================================================

mkdir -p /etc/iptables

iptables-save > /etc/iptables/rules.v4

cat > /etc/systemd/system/iptables-restore.service <<'EOF'
[Unit]
Description=Restore custom iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable iptables-restore.service

# ============================================================
# SSLH PORT 443
# ============================================================

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

rm -rf /tmp/badvpn-src

git clone \
    --depth=1 \
    https://github.com/ambrop72/badvpn.git \
    /tmp/badvpn-src

cd /tmp/badvpn-src

mkdir -p build

cd build

cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

make -j"$(nproc)"

BADVPN_BIN="$(find . \
    -type f \
    -name badvpn-udpgw \
    | head -1)"

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

for PORT in 7100 7200 7300 7400 7500
do
    systemctl enable "badvpn-${PORT}.service"
    systemctl restart "badvpn-${PORT}.service"
done

# ============================================================
# FIREWALL
# ============================================================

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 442/tcp

ufw allow 80/tcp
ufw allow 443/tcp

ufw allow 1194/udp

ufw allow 3128/tcp
ufw allow 8000/tcp
ufw allow 8080/tcp

ufw allow 7100/udp
ufw allow 7200/udp
ufw allow 7300/udp
ufw allow 7400/udp
ufw allow 7500/udp

ufw allow 1:65535/udp

ufw --force enable

# ============================================================
# OVPN FILES
# ============================================================

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
# CERTBOT HOOK
# ============================================================

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/restart-ssh-services.sh <<'EOF'
#!/bin/bash
systemctl restart nginx
systemctl restart sslh
EOF

chmod +x \
    /etc/letsencrypt/renewal-hooks/deploy/restart-ssh-services.sh

systemctl enable certbot.timer 2>/dev/null || true
systemctl restart certbot.timer 2>/dev/null || true

# ============================================================
# FINAL RESTART
# ============================================================

systemctl daemon-reload

systemctl restart ssh
systemctl restart dropbear
systemctl restart ssh-websocket
systemctl restart squid

systemctl restart openvpn-server@udp1194
systemctl restart openvpn-server@tcp443

systemctl restart nginx
systemctl restart sslh

for PORT in 7100 7200 7300 7400 7500
do
    systemctl restart "badvpn-${PORT}.service"
done

sleep 3

IP="$(curl -4 -s --max-time 10 https://api.ipify.org || true)"

if [ -z "$IP" ]; then
    IP="$(hostname -I | awk '{print $1}')"
fi

clear

echo "============================================================"
echo " INSTALL SSH SELESAI"
echo "============================================================"
echo

echo "Host IP              : $IP"
echo "Host Domain          : $DOMAIN"

echo
echo "Username SSH         : $USERNAME"
echo "Password SSH         : $PASSWORD"

echo
echo "OpenSSH              : 22"
echo "Dropbear             : 442"

echo
echo "SSH WS Non TLS       : 80"
echo "SSH WSS TLS          : 443"

echo
echo "Squid Proxy          : 8080 / 8000 / 3128"

echo
echo "BadVPN UDPGW         : 7100 / 7200 / 7300 / 7400 / 7500"

echo
echo "OpenVPN UDP          : 1194"
echo "OpenVPN TCP          : 443"

echo
echo "OVPN UDP:"
echo "/root/ovpn/openvpn-1194.ovpn"

echo
echo "OVPN TCP:"
echo "/root/ovpn/openvpn-443.ovpn"

echo
echo "============================================================"
echo " PAYLOAD WS"
echo "============================================================"

echo
echo "GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "Remote Proxy: $DOMAIN:80"

echo
echo "============================================================"
echo " PAYLOAD WSS"
echo "============================================================"

echo
echo "GET wss://$DOMAIN/ HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"

echo
echo "SNI: $DOMAIN"
echo "Remote Proxy: $DOMAIN:443"

echo
echo "============================================================"
echo " PORT"
echo "============================================================"

ss -lntup \
    | grep -E \
    ':(22|80|443|442|1194|1195|3128|8000|8080|7100|7200|7300|7400|7500|8443|10080)\b' \
    || true

echo
echo "============================================================"
echo " STATUS"
echo "============================================================"

for SERVICE in \
    ssh \
    dropbear \
    ssh-websocket \
    nginx \
    sslh \
    squid \
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
echo " SELESAI"
echo "============================================================"
