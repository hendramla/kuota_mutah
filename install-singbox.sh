#!/usr/bin/env bash
#
# install-singbox.sh
# Ubuntu 24.04 LTS — sing-box + nginx reverse proxy
# TROJAN + WS + TLS   -> path /trojan
# VMESS  + WS + TLS   -> path /vmess
# VLESS  + WS + TLS   -> path /vless
#
# Usage:
#   sudo bash install-singbox.sh yourdomain.com
#
set -euo pipefail

# ========= FIXED CREDENTIALS (sesuai permintaan) =========
TROJAN_PASS="kuota_15_dec"
UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"
PATH_TROJAN="/trojan"
PATH_VMESS="/vmess"
PATH_VLESS="/vless"

# Local (backend) ports — nginx akan reverse-proxy ke sini
PORT_TROJAN=10001
PORT_VMESS=10002
PORT_VLESS=10003

# ========= INPUT =========
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash $0 <domain>"
  exit 1
fi
DOMAIN="$1"

if [[ "$EUID" -ne 0 ]]; then
  echo "Jalankan sebagai root (sudo)."
  exit 1
fi

echo "==> Domain   : $DOMAIN"
echo "==> Trojan   : wss://$DOMAIN$PATH_TROJAN  (pass: $TROJAN_PASS)"
echo "==> VMess    : wss://$DOMAIN$PATH_VMESS   (uuid: $UUID)"
echo "==> VLESS    : wss://$DOMAIN$PATH_VLESS   (uuid: $UUID)"
echo

# ============================================================
# 1. MATIKAN IPv6 PERMANEN (tetap mati setelah reboot)
# ============================================================
echo "==> Menonaktifkan IPv6 secara permanen..."

cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system >/dev/null

# Matikan juga lewat kernel boot parameter (GRUB) agar mati sebelum sysctl jalan
if [[ -f /etc/default/grub ]]; then
  cp /etc/default/grub /etc/default/grub.bak.$(date +%s)
  if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
    if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
      sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
    fi
  else
    echo 'GRUB_CMDLINE_LINUX="ipv6.disable=1"' >> /etc/default/grub
  fi
  update-grub
fi

# Blacklist module ipv6 sebagai lapisan tambahan
cat >/etc/modprobe.d/disable-ipv6.conf <<'EOF'
blacklist ipv6
options ipv6 disable=1
EOF

echo "    IPv6 dinonaktifkan (butuh reboot untuk full effect di GRUB level)."

# ============================================================
# 2. LIMIT SISTEM (ulimit / sysctl) — DIBUAT SANGAT BESAR
# ============================================================
echo "==> Menaikkan limit sistem (file descriptor, koneksi, dll)..."

cat >/etc/security/limits.d/99-singbox.conf <<'EOF'
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
*    soft nproc  1048576
*    hard nproc  1048576
EOF

cat >/etc/sysctl.d/99-singbox-net.conf <<'EOF'
fs.file-max = 2097152
net.core.somaxconn = 1048576
net.core.netdev_max_backlog = 262144
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 2000000
EOF
sysctl --system >/dev/null

mkdir -p /etc/systemd/system.conf.d
cat >/etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
systemctl daemon-reexec || true

# ============================================================
# 3. INSTALL DEPENDENSI + NGINX + CERTBOT
# ============================================================
echo "==> Update sistem & install paket dasar..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget socat unzip jq ufw nginx certbot python3-certbot-nginx

# ============================================================
# 4. FIREWALL (IPv4 only)
# ============================================================
echo "==> Konfigurasi firewall (IPv4 only)..."
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true

# ============================================================
# 5. INSTALL SING-BOX
# ============================================================
echo "==> Install sing-box..."
curl -fsSL https://sing-box.app/install.sh | sh

mkdir -p /etc/sing-box
mkdir -p /var/log/sing-box

# ============================================================
# 6. AMBIL SSL CERT (Let's Encrypt) — standalone dulu, stop nginx sementara
# ============================================================
echo "==> Menerbitkan sertifikat TLS untuk $DOMAIN..."
systemctl stop nginx || true
certbot certonly --standalone --non-interactive --agree-tos \
  -m admin@"$DOMAIN" -d "$DOMAIN" --preferred-challenges http

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$CERT_DIR/fullchain.pem" ]]; then
  echo "!! Gagal menerbitkan sertifikat. Pastikan domain sudah mengarah ke IPv4 server ini (port 80 terbuka)."
  exit 1
fi

# ============================================================
# 7. KONFIGURASI SING-BOX (backend, tanpa TLS — TLS di-terminate nginx)
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
        { "password": "${TROJAN_PASS}" }
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
        { "uuid": "${UUID}", "alterId": 0 }
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
        { "uuid": "${UUID}" }
      ],
      "transport": {
        "type": "ws",
        "path": "${PATH_VLESS}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# Paksa sing-box hanya bind/keluar lewat IPv4 + limit besar
mkdir -p /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
Environment=GODEBUG=netdns=go+4
ExecStart=
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json -D /var/lib/sing-box
EOF

mkdir -p /var/lib/sing-box
systemctl daemon-reload

# ============================================================
# 8. KONFIGURASI NGINX (TLS termination, reverse proxy ws, IPv4 only, limit besar)
# ============================================================
echo "==> Menulis konfigurasi nginx..."

# nginx.conf global — limit besar
cat >/etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 1048576;
pid /run/nginx.pid;

events {
    worker_connections 1048576;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300s;
    keepalive_requests 100000;
    types_hash_max_size 2048;
    client_max_body_size 0;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 32k;

    server_names_hash_bucket_size 128;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    gzip on;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/sites-available/singbox.conf <<EOF
# Redirect HTTP -> HTTPS (IPv4 only)
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    client_max_body_size 0;

    location ${PATH_TROJAN} {
        proxy_pass http://127.0.0.1:${PORT_TROJAN};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ${PATH_VMESS} {
        proxy_pass http://127.0.0.1:${PORT_VMESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ${PATH_VLESS} {
        proxy_pass http://127.0.0.1:${PORT_VLESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        return 404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/singbox.conf /etc/nginx/sites-enabled/singbox.conf

# systemd override untuk limit nginx juga besar
mkdir -p /etc/systemd/system/nginx.service.d
cat >/etc/systemd/system/nginx.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
EOF
systemctl daemon-reload

nginx -t

# ============================================================
# 9. ENABLE + START SERVICES
# ============================================================
echo "==> Menyalakan service..."
systemctl enable sing-box
systemctl enable nginx
systemctl restart sing-box
systemctl restart nginx

# Auto-renew certbot + reload nginx
cat >/etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Certbot Renewal

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF

cat >/etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Run certbot renew twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true

[Timer]
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now certbot-renew.timer

# ============================================================
# 10. RINGKASAN
# ============================================================
echo
echo "=================================================================="
echo " SELESAI"
echo "=================================================================="
echo "Domain     : ${DOMAIN}"
echo
echo "[TROJAN]"
echo "  Server   : ${DOMAIN}"
echo "  Port     : 443"
echo "  Password : ${TROJAN_PASS}"
echo "  Path     : ${PATH_TROJAN}"
echo "  TLS/SNI  : ${DOMAIN}"
echo "  Link     : trojan://${TROJAN_PASS}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=${PATH_TROJAN}#Trojan-${DOMAIN}"
echo
echo "[VMESS]"
echo "  Server   : ${DOMAIN}"
echo "  Port     : 443"
echo "  UUID     : ${UUID}"
echo "  Path     : ${PATH_VMESS}"
echo "  TLS/SNI  : ${DOMAIN}"
echo
echo "[VLESS]"
echo "  Server   : ${DOMAIN}"
echo "  Port     : 443"
echo "  UUID     : ${UUID}"
echo "  Path     : ${PATH_VLESS}"
echo "  TLS/SNI  : ${DOMAIN}"
echo "  Link     : vless://${UUID}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=${PATH_VLESS}#VLESS-${DOMAIN}"
echo
echo "IPv6 dinonaktifkan permanen (sysctl + GRUB + modprobe blacklist)."
echo "Limit nofile/nproc sistem, nginx, dan sing-box dinaikkan ke 1.048.576."
echo
echo "PENTING: reboot server sekali agar penonaktifan IPv6 di level GRUB benar-benar aktif:"
echo "  sudo reboot"
echo "=================================================================="
