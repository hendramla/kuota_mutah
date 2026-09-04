#!/usr/bin/env bash
#
# install-singbox-debian12-high-connection.sh
# Debian 12 — sing-box + nginx reverse proxy
# TROJAN + WS + TLS   -> /trojan
# VMESS  + WS + TLS   -> /vmess
# VLESS  + WS + TLS   -> /vless
#
# Jalankan:
#   bash install-singbox-debian12-high-connection.sh
# atau:
#   bash install-singbox-debian12-high-connection.sh domainkamu.com
#
set -Eeuo pipefail

# ============================================================
# KONFIGURASI
# ============================================================
TROJAN_PASS="kuota_15_dec"
UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"

PATH_TROJAN="/trojan"
PATH_VMESS="/vmess"
PATH_VLESS="/vless"

PORT_TROJAN=10001
PORT_VMESS=10002
PORT_VLESS=10003

# ============================================================
# CEK ROOT + OS DEBIAN 12
# ============================================================
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Jalankan script sebagai root."
    exit 1
fi

if [[ ! -r /etc/os-release ]]; then
    echo "ERROR: /etc/os-release tidak ditemukan."
    exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
    echo "ERROR: Script ini khusus Debian 12."
    echo "OS terdeteksi: ${PRETTY_NAME:-unknown}"
    exit 1
fi

# ============================================================
# INPUT DOMAIN
# ============================================================
if [[ $# -ge 1 ]]; then
    DOMAIN="$1"
else
    read -rp "Masukkan domain (contoh: domainkamu.com): " DOMAIN
fi

DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"

if [[ -z "$DOMAIN" ]]; then
    echo "ERROR: Domain tidak boleh kosong."
    exit 1
fi

if ! [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo "ERROR: Format domain tidak valid: $DOMAIN"
    exit 1
fi

echo
echo "============================================================"
echo " DEBIAN 12 + SING-BOX HIGH CONNECTION"
echo "============================================================"
echo "Domain : $DOMAIN"
echo "Trojan : wss://$DOMAIN$PATH_TROJAN"
echo "VMess  : wss://$DOMAIN$PATH_VMESS"
echo "VLESS  : wss://$DOMAIN$PATH_VLESS"
echo "============================================================"
echo

export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. UPDATE + DEPENDENSI
# ============================================================
echo "==> Update Debian 12 dan install dependensi..."

apt-get update
apt-get install -y \
    ca-certificates curl wget socat unzip jq ufw nginx \
    certbot python3-certbot-nginx \
    iproute2 procps lsof net-tools dnsutils

timedatectl set-timezone Asia/Jakarta || true

# ============================================================
# 2. MATIKAN IPv6 PERMANEN
# ============================================================
echo "==> Menonaktifkan IPv6..."

cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

if [[ -f /etc/default/grub ]]; then
    cp -a /etc/default/grub "/etc/default/grub.bak.$(date +%Y%m%d-%H%M%S)"

    if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
        fi
    else
        echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' >> /etc/default/grub
    fi

    update-grub || true
fi

cat >/etc/modprobe.d/disable-ipv6.conf <<'EOF'
blacklist ipv6
options ipv6 disable=1
EOF

# ============================================================
# 3. LIMIT USER / FILE DESCRIPTOR
# ============================================================
echo "==> Menaikkan file descriptor dan process limit..."

cat >/etc/security/limits.d/99-singbox-high-connection.conf <<'EOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576

*       soft    nproc   1048576
*       hard    nproc   1048576
root    soft    nproc   1048576
root    hard    nproc   1048576
EOF

mkdir -p /etc/systemd/system.conf.d

cat >/etc/systemd/system.conf.d/99-high-connection-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultTasksMax=1048576
EOF

# ============================================================
# 4. SYSCTL — HIGH CONNECTION / HIGH CONCURRENCY
# ============================================================
echo "==> Menerapkan tuning network untuk koneksi ramai..."

cat >/etc/sysctl.d/99-singbox-high-connection.conf <<'EOF'
# ------------------------------------------------------------
# FILE DESCRIPTOR
# ------------------------------------------------------------
fs.nr_open = 2097152
fs.file-max = 4194304

# ------------------------------------------------------------
# QUEUE / BACKLOG
# ------------------------------------------------------------
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 262144
net.ipv4.tcp_max_syn_backlog = 262144

# ------------------------------------------------------------
# TCP PORT / TIME_WAIT
# ------------------------------------------------------------
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000

# ------------------------------------------------------------
# TCP KEEPALIVE
# ------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ------------------------------------------------------------
# TCP BUFFER
# ------------------------------------------------------------
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# ------------------------------------------------------------
# TCP STABILITY / PERFORMANCE
# ------------------------------------------------------------
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# ------------------------------------------------------------
# BBR + FQ
# ------------------------------------------------------------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ------------------------------------------------------------
# ROUTING
# ------------------------------------------------------------
net.ipv4.ip_forward = 1
EOF

sysctl --system

# Pastikan BBR tersedia
modprobe tcp_bbr 2>/dev/null || true

# ============================================================
# 5. FIREWALL
# ============================================================
echo "==> Konfigurasi UFW..."

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ============================================================
# 6. INSTALL SING-BOX RESMI
# ============================================================
echo "==> Install sing-box..."

curl -fsSL https://sing-box.app/install.sh | sh

SINGBOX_BIN="$(command -v sing-box || true)"

if [[ -z "$SINGBOX_BIN" || ! -x "$SINGBOX_BIN" ]]; then
    echo "ERROR: Binary sing-box tidak ditemukan setelah instalasi."
    exit 1
fi

echo "    Binary sing-box: $SINGBOX_BIN"

mkdir -p /etc/sing-box
mkdir -p /var/lib/sing-box
mkdir -p /var/log/sing-box

# ============================================================
# 7. SSL LET'S ENCRYPT
# ============================================================
echo "==> Menerbitkan sertifikat TLS untuk $DOMAIN..."

systemctl stop nginx || true

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --preferred-challenges http \
    -m "admin@$DOMAIN" \
    -d "$DOMAIN"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

if [[ ! -f "$CERT_DIR/fullchain.pem" || ! -f "$CERT_DIR/privkey.pem" ]]; then
    echo "ERROR: Sertifikat SSL tidak ditemukan."
    echo "Pastikan DNS A domain mengarah ke IPv4 VPS dan port 80 dapat diakses."
    exit 1
fi

# ============================================================
# 8. CONFIG SING-BOX
# ============================================================
echo "==> Menulis konfigurasi sing-box..."

cat >/etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "output": "/var/log/sing-box/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "127.0.0.1",
      "listen_port": ${PORT_TROJAN},
      "users": [
        {
          "password": "${TROJAN_PASS}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${PATH_TROJAN}"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${PORT_VMESS},
      "users": [
        {
          "uuid": "${UUID}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${PATH_VMESS}"
      }
    },
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${PORT_VLESS},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${PATH_VLESS}"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

"$SINGBOX_BIN" check -c /etc/sing-box/config.json

# ============================================================
# 9. SYSTEMD LIMIT SING-BOX
# ============================================================
echo "==> Menaikkan limit service sing-box..."

mkdir -p /etc/systemd/system/sing-box.service.d

cat >/etc/systemd/system/sing-box.service.d/override.conf <<EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=1048576
Restart=always
RestartSec=2s
Environment=GODEBUG=netdns=go+4

ExecStart=
ExecStart=${SINGBOX_BIN} run -c /etc/sing-box/config.json -D /var/lib/sing-box
EOF

# ============================================================
# 10. NGINX GLOBAL HIGH CONNECTION
# ============================================================
echo "==> Menulis nginx.conf high connection..."

cp -a /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
worker_shutdown_timeout 10s;
pid /run/nginx.pid;

events {
    use epoll;
    worker_connections 131072;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Kurangi I/O saat koneksi sangat ramai.
    access_log off;
    error_log /var/log/nginx/error.log warn;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # HTTP keepalive; koneksi WebSocket memakai proxy timeout di location.
    keepalive_timeout 65s;
    keepalive_requests 100000;

    reset_timedout_connection on;

    server_names_hash_bucket_size 128;
    types_hash_max_size 4096;

    client_max_body_size 0;
    client_body_buffer_size 128k;
    large_client_header_buffers 8 32k;

    # Tidak perlu buffering untuk trafik tunnel/WebSocket.
    proxy_buffering off;
    proxy_request_buffering off;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

rm -f /etc/nginx/sites-enabled/default

# ============================================================
# 11. NGINX TROJAN / VMESS / VLESS WEBSOCKET
# ============================================================
cat >/etc/nginx/sites-available/singbox.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;

    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    client_max_body_size 0;

    location ${PATH_TROJAN} {
        proxy_pass http://127.0.0.1:${PORT_TROJAN};
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

    location ${PATH_VMESS} {
        proxy_pass http://127.0.0.1:${PORT_VMESS};
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

    location ${PATH_VLESS} {
        proxy_pass http://127.0.0.1:${PORT_VLESS};
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

    location / {
        return 404;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/singbox.conf /etc/nginx/sites-enabled/singbox.conf

# ============================================================
# 12. SYSTEMD LIMIT NGINX
# ============================================================
echo "==> Menaikkan limit service nginx..."

mkdir -p /etc/systemd/system/nginx.service.d

cat >/etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=1048576
EOF

systemctl daemon-reexec || true
systemctl daemon-reload

nginx -t

# ============================================================
# 13. START SERVICE
# ============================================================
echo "==> Menyalakan sing-box dan nginx..."

systemctl enable sing-box
systemctl enable nginx

systemctl restart sing-box
systemctl restart nginx

# ============================================================
# 14. CERTBOT AUTO RENEW
# ============================================================
echo "==> Mengaktifkan auto-renew SSL..."

systemctl enable --now certbot.timer 2>/dev/null || true

# ============================================================
# 15. PEMERIKSAAN
# ============================================================
echo
echo "==> Pemeriksaan service..."

systemctl --no-pager --full status sing-box | head -n 15 || true
echo
systemctl --no-pager --full status nginx | head -n 15 || true

echo
echo "Limit sing-box:"
systemctl show sing-box -p LimitNOFILE -p TasksMax || true

echo
echo "Limit nginx:"
systemctl show nginx -p LimitNOFILE -p TasksMax || true

echo
echo "Network tuning:"
sysctl net.core.somaxconn \
       net.core.netdev_max_backlog \
       net.ipv4.tcp_max_syn_backlog \
       net.ipv4.tcp_max_tw_buckets \
       net.ipv4.tcp_congestion_control \
       fs.file-max \
       fs.nr_open || true

# ============================================================
# 16. RINGKASAN
# ============================================================
echo
echo "=================================================================="
echo " SELESAI - DEBIAN 12 HIGH CONNECTION"
echo "=================================================================="
echo "Domain     : ${DOMAIN}"
echo "Sing-box   : $("$SINGBOX_BIN" version | head -n1)"
echo
echo "[TROJAN]"
echo "Server     : ${DOMAIN}"
echo "Port       : 443"
echo "Password   : ${TROJAN_PASS}"
echo "Path       : ${PATH_TROJAN}"
echo "TLS/SNI    : ${DOMAIN}"
echo "Link       : trojan://${TROJAN_PASS}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=${PATH_TROJAN}#Trojan-${DOMAIN}"
echo
echo "[VMESS]"
echo "Server     : ${DOMAIN}"
echo "Port       : 443"
echo "UUID       : ${UUID}"
echo "Path       : ${PATH_VMESS}"
echo "TLS/SNI    : ${DOMAIN}"
echo
echo "[VLESS]"
echo "Server     : ${DOMAIN}"
echo "Port       : 443"
echo "UUID       : ${UUID}"
echo "Path       : ${PATH_VLESS}"
echo "TLS/SNI    : ${DOMAIN}"
echo "Link       : vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=${PATH_VLESS}#VLESS-${DOMAIN}"
echo
echo "LIMIT:"
echo "NOFILE              : 1,048,576"
echo "NPROC               : 1,048,576"
echo "TasksMax            : 1,048,576"
echo "fs.file-max          : 4,194,304"
echo "fs.nr_open           : 2,097,152"
echo "Nginx worker_conn    : 131,072 per worker"
echo "somaxconn            : 65,535"
echo "tcp_max_syn_backlog  : 262,144"
echo "tcp_max_tw_buckets   : 2,000,000"
echo "TCP congestion       : BBR + FQ"
echo
echo "IPv6 dinonaktifkan melalui sysctl + GRUB + modprobe."
echo
echo "REBOOT sekali agar seluruh pengaturan kernel/IPv6 aktif sempurna:"
echo "  reboot"
echo "=================================================================="
