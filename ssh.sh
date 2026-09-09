bash <<'INSTALL_SCRIPT'
set -e

clear
echo "============================================================"
echo " SSH + WEBSOCKET + TLS + DROPBEAR + SQUID + OPENVPN + BADVPN"
echo " Debian 12"
echo "============================================================"
echo

read -rp "Masukkan domain: " DOMAIN

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"

if [ -z "$DOMAIN" ]; then
    echo "Domain tidak boleh kosong."
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
# 1. TIMEZONE
# ============================================================

timedatectl set-timezone Asia/Jakarta

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 2. UPDATE + PACKAGE
# ============================================================

apt-get update

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
    iptables-persistent \
    netfilter-persistent \
    build-essential \
    cmake \
    nodejs \
    npm

# ============================================================
# 3. SSH USER
# ============================================================

if id "$USERNAME" >/dev/null 2>&1; then
    echo "$USERNAME:$PASSWORD" | chpasswd
else
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
fi

# ============================================================
# 4. OPENSSH PORT 22
# ============================================================

cp /etc/ssh/sshd_config \
   /etc/ssh/sshd_config.backup.$(date +%s) || true

sed -i '/^[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<EOF

Port 22
PasswordAuthentication yes
PermitRootLogin prohibit-password
UsePAM yes
EOF

systemctl enable ssh
systemctl restart ssh

# ============================================================
# 5. DROPBEAR PORT 442
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
# 6. NODE.JS SSH WEBSOCKET SERVER
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

npm install --omit=dev

cat > /opt/ssh-websocket/server.js <<'EOF'
const http = require('http');
const net = require('net');
const WebSocket = require('ws');

const HOST = '127.0.0.1';
const PORT = 10080;

const server = http.createServer((req, res) => {
    res.writeHead(200, {
        'Content-Type': 'text/plain',
        'Connection': 'keep-alive'
    });

    res.end('SSH WebSocket Server\n');
});

const wss = new WebSocket.Server({
    noServer: true,
    perMessageDeflate: false
});

server.on('upgrade', (req, socket, head) => {
    wss.handleUpgrade(req, socket, head, (ws) => {
        wss.emit('connection', ws, req);
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

        try { ws.close(); } catch (_) {}
        try { ssh.destroy(); } catch (_) {}
    };

    ssh.on('connect', () => {
        ws.on('message', (data) => {
            if (!ssh.destroyed) {
                ssh.write(Buffer.from(data));
            }
        });

        ssh.on('data', (data) => {
            if (ws.readyState === WebSocket.OPEN) {
                ws.send(data, { binary: true });
            }
        });
    });

    ws.on('close', closeAll);
    ws.on('error', closeAll);

    ssh.on('close', closeAll);
    ssh.on('error', closeAll);
});

server.listen(PORT, HOST, () => {
    console.log(`SSH WebSocket listening on ${HOST}:${PORT}`);
});
EOF

cat > /etc/systemd/system/ssh-websocket.service <<'EOF'
[Unit]
Description=SSH WebSocket Tunnel
After=network.target ssh.service
Requires=ssh.service

[Service]
Type=simple
WorkingDirectory=/opt/ssh-websocket
ExecStart=/usr/bin/node /opt/ssh-websocket/server.js
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ssh-websocket

# ============================================================
# 7. STOP SERVICES BEFORE CERTBOT
# ============================================================

systemctl stop nginx 2>/dev/null || true
systemctl stop sslh 2>/dev/null || true

# ============================================================
# 8. CERTIFICATE
# ============================================================

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$DOMAIN"
fi

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    echo
    echo "============================================"
    echo "CERTIFICATE GAGAL"
    echo "============================================"
    echo "Pastikan:"
    echo "1. Domain mengarah ke IP VPS"
    echo "2. Port 80 terbuka"
    echo "3. Cloudflare sementara DNS Only"
    exit 1
fi

# ============================================================
# 9. NGINX
#
# PORT 80   = WS NON TLS
# 127.0.0.1:8443 = WSS TLS backend untuk sslh :443
# ============================================================

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/ssh-websocket <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

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
# 10. SQUID
# Ports:
# 8080
# 8000
# 3128
#
# Authentication menggunakan mashen / mashen
# ============================================================

apt-get install -y apache2-utils

htpasswd -bc /etc/squid/passwd "$USERNAME" "$PASSWORD"

cat > /etc/squid/squid.conf <<EOF
http_port 3128
http_port 8000
http_port 8080

visible_hostname $DOMAIN

auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm SSH-PROXY
auth_param basic credentialsttl 24 hours

acl authenticated proxy_auth REQUIRED

http_access allow authenticated
http_access deny all

request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Cache-Control allow all

forwarded_for delete
via off

dns_v4_first on

cache deny all

access_log /var/log/squid/access.log
EOF

systemctl enable squid
systemctl restart squid

# ============================================================
# 11. OPENVPN PKI
# ============================================================

mkdir -p /etc/openvpn/server

rm -rf /etc/openvpn/easy-rsa
make-cadir /etc/openvpn/easy-rsa

cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="SSH-VPN-CA"

./easyrsa init-pki
./easyrsa build-ca nopass

EASYRSA_CERT_EXPIRE=3650 \
./easyrsa build-server-full server nopass

cp pki/ca.crt /etc/openvpn/server/
cp pki/issued/server.crt /etc/openvpn/server/
cp pki/private/server.key /etc/openvpn/server/

openvpn --genkey secret /etc/openvpn/server/tls-crypt.key

PAM_PLUGIN="$(find /usr/lib -name openvpn-plugin-auth-pam.so 2>/dev/null | head -1)"

if [ -z "$PAM_PLUGIN" ]; then
    echo "Plugin PAM OpenVPN tidak ditemukan."
    exit 1
fi

# ============================================================
# 12. OPENVPN UDP 1194
# ============================================================

cat > /etc/openvpn/server/udp1194.conf <<EOF
port 1194
proto udp
dev tun0

server 10.8.0.0 255.255.255.0
topology subnet

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
# 13. OPENVPN TCP BACKEND
#
# sslh :443 => OpenVPN 127.0.0.1:1195
# ============================================================

cat > /etc/openvpn/server/tcp443.conf <<EOF
local 127.0.0.1
port 1195
proto tcp-server
dev tun1

server 10.9.0.0 255.255.255.0
topology subnet

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

systemctl enable --now openvpn-server@udp1194
systemctl enable --now openvpn-server@tcp443

# ============================================================
# 14. IP FORWARD
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

fs.file-max=2097152
EOF

sysctl --system

# ============================================================
# 15. NAT OPENVPN
# ============================================================

IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"

if [ -z "$IFACE" ]; then
    echo "Interface internet tidak ditemukan."
    exit 1
fi

iptables -t nat -C POSTROUTING \
    -s 10.8.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING \
    -s 10.8.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE

iptables -t nat -C POSTROUTING \
    -s 10.9.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING \
    -s 10.9.0.0/24 \
    -o "$IFACE" \
    -j MASQUERADE

iptables -C FORWARD \
    -s 10.8.0.0/24 \
    -j ACCEPT 2>/dev/null || \
iptables -A FORWARD \
    -s 10.8.0.0/24 \
    -j ACCEPT

iptables -C FORWARD \
    -d 10.8.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null || \
iptables -A FORWARD \
    -d 10.8.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

iptables -C FORWARD \
    -s 10.9.0.0/24 \
    -j ACCEPT 2>/dev/null || \
iptables -A FORWARD \
    -s 10.9.0.0/24 \
    -j ACCEPT

iptables -C FORWARD \
    -d 10.9.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT 2>/dev/null || \
iptables -A FORWARD \
    -d 10.9.0.0/24 \
    -m conntrack \
    --ctstate ESTABLISHED,RELATED \
    -j ACCEPT

netfilter-persistent save

# ============================================================
# 16. SSLH MULTIPLEX PORT 443
#
# TLS/WSS   -> nginx 127.0.0.1:8443
# OpenVPN   -> 127.0.0.1:1195
# ============================================================

cat > /etc/default/sslh <<'EOF'
RUN=yes
DAEMON=/usr/sbin/sslh

DAEMON_OPTS="--user sslh \
--listen 0.0.0.0:443 \
--tls 127.0.0.1:8443 \
--openvpn 127.0.0.1:1195 \
--timeout 3"
EOF

systemctl daemon-reload
systemctl enable sslh
systemctl restart sslh

# ============================================================
# 17. BADVPN UDPGW
# ============================================================

cd /tmp

rm -rf /tmp/badvpn-src

git clone --depth=1 \
    https://github.com/ambrop72/badvpn.git \
    /tmp/badvpn-src

cd /tmp/badvpn-src

rm -rf build
mkdir build
cd build

cmake .. \
    -DBUILD_NOTHING_BY_DEFAULT=1 \
    -DBUILD_UDPGW=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

make -j"$(nproc)"

BADVPN_BIN="$(find . -type f -name badvpn-udpgw | head -1)"

if [ -z "$BADVPN_BIN" ]; then
    echo "Build BadVPN gagal."
    exit 1
fi

install -m 755 "$BADVPN_BIN" /usr/local/bin/badvpn-udpgw

for PORT in 7100 7200 7300 7400 7500
do

cat > "/etc/systemd/system/badvpn-${PORT}.service" <<EOF
[Unit]
Description=BadVPN UDPGW $PORT
After=network.target

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
    systemctl enable --now "badvpn-${PORT}.service"
done

# ============================================================
# 18. FIREWALL
# ============================================================

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 442/tcp

ufw allow 1194/udp

ufw allow 3128/tcp
ufw allow 8000/tcp
ufw allow 8080/tcp

ufw allow 7100/udp
ufw allow 7200/udp
ufw allow 7300/udp
ufw allow 7400/udp
ufw allow 7500/udp

#
# UDP CUSTOM 1-65535
#
ufw allow 1:65535/udp

ufw --force enable

# ============================================================
# 19. OPENVPN CLIENT CONFIG UDP
# ============================================================

mkdir -p /root/ovpn

CA="$(cat /etc/openvpn/server/ca.crt)"
TLSCRYPT="$(cat /etc/openvpn/server/tls-crypt.key)"

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
$CA
</ca>

<tls-crypt>
$TLSCRYPT
</tls-crypt>
EOF

# ============================================================
# 20. OPENVPN CLIENT CONFIG TCP 443
# ============================================================

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
$CA
</ca>

<tls-crypt>
$TLSCRYPT
</tls-crypt>
EOF

# ============================================================
# 21. CERTBOT AUTO RENEW HOOK
# ============================================================

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/restart-ssh-tls.sh <<'EOF'
#!/bin/bash

systemctl restart nginx
systemctl restart sslh
EOF

chmod +x \
    /etc/letsencrypt/renewal-hooks/deploy/restart-ssh-tls.sh

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

# ============================================================
# 22. RESTART EVERYTHING
# ============================================================

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

# ============================================================
# 23. STATUS
# ============================================================

IP="$(curl -4 -s --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')"

clear

echo "============================================================"
echo " INSTALASI SELESAI"
echo "============================================================"
echo
echo "Host IP              : $IP"
echo "Domain               : $DOMAIN"
echo
echo "Username SSH         : $USERNAME"
echo "Password SSH         : $PASSWORD"
echo
echo "OpenSSH              : 22"
echo "Dropbear             : 442"
echo
echo "SSH WebSocket        : 80"
echo "SSH WebSocket TLS    : 443"
echo
echo "Squid Proxy          : 3128 / 8000 / 8080"
echo "Squid Username       : $USERNAME"
echo "Squid Password       : $PASSWORD"
echo
echo "BadVPN UDPGW         : 7100"
echo "                     : 7200"
echo "                     : 7300"
echo "                     : 7400"
echo "                     : 7500"
echo
echo "OpenVPN UDP          : 1194"
echo "OpenVPN TCP          : 443"
echo
echo "OVPN UDP Config      : /root/ovpn/openvpn-1194.ovpn"
echo "OVPN TCP 443 Config  : /root/ovpn/openvpn-443.ovpn"
echo
echo "============================================================"
echo " PAYLOAD SSH WEBSOCKET NON TLS"
echo "============================================================"
echo
echo "GET / HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"
echo
echo "Remote Proxy : $DOMAIN:80"
echo
echo "============================================================"
echo " PAYLOAD SSH WEBSOCKET TLS / WSS"
echo "============================================================"
echo
echo "GET wss://$DOMAIN/ HTTP/1.1[crlf]Host: $DOMAIN[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]"
echo
echo "SNI          : $DOMAIN"
echo "Remote Proxy : $DOMAIN:443"
echo
echo "============================================================"
echo " LISTENING PORTS"
echo "============================================================"
echo

ss -lntup | grep -E \
':(22|80|443|442|1194|1195|3128|8000|8080|7100|7200|7300|7400|7500|8443|10080)\b' || true

echo
echo "============================================================"
echo " SERVICE STATUS"
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
    printf "%-30s : " "$SERVICE"

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
echo
echo "SSH:"
echo "ssh $USERNAME@$DOMAIN -p 22"
echo
echo "Akun:"
echo "Username : $USERNAME"
echo "Password : $PASSWORD"
echo
echo "Untuk melihat file OVPN:"
echo "ls -lh /root/ovpn/"
echo
INSTALL_SCRIPT
