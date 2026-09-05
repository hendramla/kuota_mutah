#!/bin/bash
set -Eeuo pipefail

clear
echo "============================================================"
echo " SING-BOX + NGINX + TLS - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " HIGH CONNECTION + IPV4 ONLY + BBR"
echo "============================================================"
echo

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Jalankan sebagai root."
  exit 1
fi

read -rp "Masukkan domain (contoh: anym-1.heen.my.id): " DOMAIN
DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"

if [[ -z "$DOMAIN" ]]; then
  echo "ERROR: Domain tidak boleh kosong."
  exit 1
fi

if ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
  echo "ERROR: Format domain tidak valid."
  exit 1
fi

UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"
TROJAN_PASS="kuota_15_dec"
TROJAN_PORT="10001"
VMESS_PORT="10002"
VLESS_PORT="10003"

export DEBIAN_FRONTEND=noninteractive

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP"
cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true
cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true

timedatectl set-timezone Asia/Jakarta

apt-get update
apt-get install -y curl wget unzip zip socat ca-certificates gnupg openssl nginx certbot ufw jq mtr-tiny dnsutils iproute2 net-tools procps

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
npm install -g pm2

mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get update
apt-get install -y sing-box

cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

if [ ! -L /etc/resolv.conf ]; then
  cp -a /etc/resolv.conf /etc/resolv.conf.backup.$(date +%F-%H%M%S) 2>/dev/null || true
  cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF
fi

echo tcp_bbr > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-singbox-high-connection.conf <<'EOF'
fs.nr_open = 2097152
fs.file-max = 4194304
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
EOF
sysctl --system || true

cat > /etc/security/limits.d/99-singbox-high-connection.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-high-connection-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultTasksMax=1048576
EOF

if ! id sing-box >/dev/null 2>&1; then
  useradd --system --home /var/lib/sing-box --shell /usr/sbin/nologin sing-box
fi
mkdir -p /etc/sing-box /var/lib/sing-box /var/log/sing-box
touch /var/log/sing-box/sing-box.log
chown -R sing-box:sing-box /var/lib/sing-box /var/log/sing-box
chmod 755 /var/log/sing-box
chmod 664 /var/log/sing-box/sing-box.log

cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level":"warn","output":"/var/log/sing-box/sing-box.log","timestamp":true},
  "inbounds": [
    {"type":"trojan","tag":"trojan-in","listen":"127.0.0.1","listen_port":${TROJAN_PORT},"users":[{"password":"${TROJAN_PASS}"}],"transport":{"type":"ws","path":"/trojan"}},
    {"type":"vmess","tag":"vmess-in","listen":"127.0.0.1","listen_port":${VMESS_PORT},"users":[{"uuid":"${UUID}","alterId":0}],"transport":{"type":"ws","path":"/vmess"}},
    {"type":"vless","tag":"vless-in","listen":"127.0.0.1","listen_port":${VLESS_PORT},"users":[{"uuid":"${UUID}"}],"transport":{"type":"ws","path":"/vless"}}
  ],
  "outbounds": [{"type":"direct","tag":"direct"}],
  "route": {"rules":[{"ip_version":6,"action":"reject"},{"action":"resolve","strategy":"ipv4_only"}]}
}
EOF

/usr/bin/sing-box check -c /etc/sing-box/config.json

systemctl stop sing-box 2>/dev/null || true
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sing-box
Group=sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json -D /var/lib/sing-box
Restart=always
RestartSec=2s
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=1048576
TimeoutStopSec=30s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
sleep 2
if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 100 --no-pager
  exit 1
fi

cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
    use epoll;
    worker_connections 131072;
    multi_accept on;
}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65s;
    keepalive_requests 100000;
    types_hash_max_size 4096;
    server_names_hash_bucket_size 128;
    proxy_buffering off;
    proxy_request_buffering off;
    proxy_socket_keepalive on;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;
    gzip off;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=1048576
EOF
systemctl daemon-reload
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/www/html/.well-known/acme-challenge

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {
    listen 80 default_server;
    server_name ${DOMAIN} _;
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; default_type text/plain; }
    location / { return 200 "sing-box server\n"; add_header Content-Type text/plain; }
}
EOF
ln -sf /etc/nginx/sites-available/singbox.conf /etc/nginx/sites-enabled/singbox.conf
nginx -t
systemctl enable nginx
systemctl restart nginx

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
  certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {
    listen 80 default_server;
    server_name ${DOMAIN} _;
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; default_type text/plain; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2 default_server backlog=65535;
    server_name ${DOMAIN} _;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    client_max_body_size 0;
    client_body_timeout 86400s;
    send_timeout 86400s;

    location /trojan {
        proxy_pass http://127.0.0.1:${TROJAN_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
    }
    location /vmess {
        proxy_pass http://127.0.0.1:${VMESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
    }
    location /vless {
        proxy_pass http://127.0.0.1:${VLESS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
    }
    location / { return 200 "OK\n"; add_header Content-Type text/plain; }
}
EOF

nginx -t
systemctl restart nginx
systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

cat > /etc/logrotate.d/sing-box <<'EOF'
/var/log/sing-box/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

systemctl daemon-reload
systemctl restart sing-box
systemctl restart nginx
sleep 3

echo
printf '%s\n' "============================================================" \
" INSTALLASI SELESAI" \
"============================================================" \
"Domain      : $DOMAIN" \
"Trojan Pass : $TROJAN_PASS" \
"UUID        : $UUID" \
"Trojan WS   : /trojan" \
"VMess WS    : /vmess" \
"VLESS WS    : /vless" \
"Port TLS    : 443" \
"IPv6        : OFF" \
"IPv4        : ONLY" \
"============================================================"

echo "===== STATUS ====="
systemctl is-active sing-box nginx || true

echo "===== PORT ====="
ss -lntp | grep -E ':80 |:443 |:10001|:10002|:10003' || true

echo "===== BBR ====="
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control || true

echo "===== IPV6 ====="
sysctl net.ipv6.conf.all.disable_ipv6 || true

echo "===== TEST CONFIG ====="
sing-box check -c /etc/sing-box/config.json
nginx -t
