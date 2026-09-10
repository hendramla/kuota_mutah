cat > /root/install-xray.sh <<'INSTALLER'
#!/bin/bash

set -e

# ============================================================
# XRAY CORE + NGINX WS TLS
# Debian 12
# TROJAN / VLESS / VMESS
# ============================================================

if [ "$(id -u)" != "0" ]; then
    echo "Jalankan sebagai root."
    exit 1
fi

clear

echo "============================================================"
echo "     XRAY CORE + NGINX WEBSOCKET TLS INSTALLER"
echo "============================================================"
echo

read -rp "Masukkan domain: " DOMAIN

DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')

if [ -z "$DOMAIN" ]; then
    echo "Domain tidak boleh kosong."
    exit 1
fi

# ============================================================
# ACCOUNT
# ============================================================

TROJAN_PASSWORD="kuota_15_dec"
VLESS_UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"
VMESS_UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"

TROJAN_PORT="10001"
VLESS_PORT="10002"
VMESS_PORT="10003"

TROJAN_PATH="/trojan"
VLESS_PATH="/vless"
VMESS_PATH="/vmess"

export DEBIAN_FRONTEND=noninteractive

echo
echo "============================================================"
echo " 1. UPDATE SYSTEM"
echo "============================================================"

apt-get update

apt-get install -y \
    curl \
    wget \
    unzip \
    ca-certificates \
    gnupg \
    openssl \
    nginx \
    certbot \
    chrony

# ============================================================
# TIMEZONE / CLOCK
# ============================================================

echo
echo "============================================================"
echo " 2. TIMEZONE + TIME SYNC"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta || true

systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony || true

timedatectl set-ntp true >/dev/null 2>&1 || true

# ============================================================
# FIREWALL
# ============================================================

echo
echo "============================================================"
echo " 3. FIREWALL"
echo "============================================================"

if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
fi

# ============================================================
# INSTALL XRAY OFFICIAL
# ============================================================

echo
echo "============================================================"
echo " 4. INSTALL XRAY CORE"
echo "============================================================"

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root

mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

# ============================================================
# XRAY CONFIG
# ============================================================

echo
echo "============================================================"
echo " 5. CREATE XRAY CONFIG"
echo "============================================================"

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },

  "inbounds": [
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": ${TROJAN_PORT},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${TROJAN_PASSWORD}",
            "email": "trojan@local"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${TROJAN_PATH}"
        }
      }
    },

    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "email": "vless@local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${VLESS_PATH}"
        }
      }
    },

    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${VMESS_UUID}",
            "alterId": 0,
            "email": "vmess@local"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${VMESS_PATH}"
        }
      }
    }
  ],

  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "blocked",
      "protocol": "blackhole"
    }
  ]
}
EOF

# ============================================================
# TEST XRAY CONFIG
# ============================================================

echo
echo "============================================================"
echo " 6. TEST XRAY CONFIG"
echo "============================================================"

if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json; then
    echo "Xray config: OK"
else
    echo
    echo "ERROR: konfigurasi Xray tidak valid."
    exit 1
fi

# ============================================================
# XRAY LIMIT
# ============================================================

mkdir -p /etc/systemd/system/xray.service.d

cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
Restart=always
RestartSec=3s
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ============================================================
# REMOVE DEFAULT NGINX
# ============================================================

echo
echo "============================================================"
echo " 7. PREPARE NGINX"
echo "============================================================"

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default
rm -f /etc/nginx/conf.d/xray.conf

systemctl stop nginx || true

# ============================================================
# CERTIFICATE
# ============================================================

echo
echo "============================================================"
echo " 8. REQUEST LET'S ENCRYPT CERTIFICATE"
echo "============================================================"
echo
echo "Domain : ${DOMAIN}"
echo
echo "Pastikan:"
echo " - A record ${DOMAIN} mengarah ke IP VPS ini"
echo " - Port 80 terbuka"
echo " - Jika Cloudflare dipakai, DNS Only lebih aman saat issuance"
echo

certbot certonly \
    --standalone \
    --preferred-challenges http \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    -d "${DOMAIN}"

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
    echo "SSL certificate tidak ditemukan."
    exit 1
fi

# ============================================================
# NGINX GLOBAL LIMITS
# ============================================================

echo
echo "============================================================"
echo " 9. OPTIMIZE NGINX"
echo "============================================================"

sed -i '/^worker_rlimit_nofile/d' /etc/nginx/nginx.conf
sed -i '/^worker_processes/a worker_rlimit_nofile 1048576;' /etc/nginx/nginx.conf

sed -i 's/worker_connections [0-9]*;/worker_connections 65535;/' /etc/nginx/nginx.conf || true

# ============================================================
# NGINX XRAY CONFIG
# ============================================================

cat > /etc/nginx/conf.d/xray.conf <<EOF
# ============================================================
# Xray Core Reverse Proxy
# Domain: ${DOMAIN}
# ============================================================

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

upstream xray_trojan {
    server 127.0.0.1:${TROJAN_PORT};
    keepalive 64;
}

upstream xray_vless {
    server 127.0.0.1:${VLESS_PORT};
    keepalive 64;
}

upstream xray_vmess {
    server 127.0.0.1:${VMESS_PORT};
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    server_name ${DOMAIN};

    listen 443 ssl http2 reuseport;
    listen [::]:443 ssl http2 reuseport;

    server_tokens off;

    # ========================================================
    # TROJAN WebSocket
    # ========================================================

    location ${TROJAN_PATH} {
        proxy_http_version 1.1;

        proxy_pass http://xray_trojan;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_redirect off;
        proxy_buffering off;

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }

    # ========================================================
    # VLESS WebSocket
    # ========================================================

    location ${VLESS_PATH} {
        proxy_http_version 1.1;

        proxy_pass http://xray_vless;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_redirect off;
        proxy_buffering off;

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }

    # ========================================================
    # VMESS WebSocket
    # ========================================================

    location ${VMESS_PATH} {
        proxy_http_version 1.1;

        proxy_pass http://xray_vmess;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_redirect off;
        proxy_buffering off;

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
    }

    # ========================================================
    # DEFAULT PAGE
    # ========================================================

    location / {
        default_type text/plain;
        return 200 "OK\n";
    }

    # ========================================================
    # TLS
    # ========================================================

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;

    ssl_prefer_server_ciphers off;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_certificate "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${DOMAIN}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${DOMAIN}/chain.pem";

    resolver 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 valid=60s;
    resolver_timeout 2s;

    # ========================================================
    # GZIP
    # ========================================================

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_min_length 256;

    gzip_types
        application/atom+xml
        application/geo+json
        application/javascript
        application/x-javascript
        application/json
        application/ld+json
        application/manifest+json
        application/rdf+xml
        application/rss+xml
        application/xhtml+xml
        application/xml
        application/wasm
        font/eot
        font/otf
        font/ttf
        image/svg+xml
        text/css
        text/javascript
        text/plain
        text/xml;
}
EOF

# ============================================================
# NGINX TEST
# ============================================================

echo
echo "============================================================"
echo " 10. TEST NGINX"
echo "============================================================"

nginx -t

systemctl enable nginx
systemctl restart nginx

# ============================================================
# CERTBOT AUTO RENEW + NGINX RELOAD
# ============================================================

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
/usr/bin/systemctl reload nginx
EOF

chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

systemctl enable certbot.timer >/dev/null 2>&1 || true
systemctl start certbot.timer >/dev/null 2>&1 || true

# ============================================================
# SYSCTL NETWORK OPTIMIZATION
# ============================================================

echo
echo "============================================================"
echo " 11. NETWORK OPTIMIZATION"
echo "============================================================"

cat > /etc/sysctl.d/99-xray.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

net.core.somaxconn=65535
net.core.netdev_max_backlog=16384

net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

fs.file-max=2097152
EOF

sysctl --system >/dev/null 2>&1 || true

# ============================================================
# CREATE VMESS LINK
# ============================================================

VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "${DOMAIN}-VMESS",
  "add": "${DOMAIN}",
  "port": "443",
  "id": "${VMESS_UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${DOMAIN}",
  "path": "${VMESS_PATH}",
  "tls": "tls",
  "sni": "${DOMAIN}",
  "alpn": ""
}
EOF
)

VMESS_BASE64=$(printf '%s' "${VMESS_JSON}" | base64 -w 0)

TROJAN_LINK="trojan://${TROJAN_PASSWORD}@${DOMAIN}:443?security=tls&type=ws&host=${DOMAIN}&path=%2Ftrojan&sni=${DOMAIN}#${DOMAIN}-TROJAN"

VLESS_LINK="vless://${VLESS_UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=%2Fvless&sni=${DOMAIN}#${DOMAIN}-VLESS"

VMESS_LINK="vmess://${VMESS_BASE64}"

# ============================================================
# SAVE ACCOUNT
# ============================================================

cat > /root/xray-account.txt <<EOF
============================================================
XRAY ACCOUNT
============================================================

DOMAIN
------
${DOMAIN}

============================================================
TROJAN + WEBSOCKET + TLS
============================================================

Address  : ${DOMAIN}
Port     : 443
Password : ${TROJAN_PASSWORD}
Network  : WebSocket
Path     : ${TROJAN_PATH}
Host     : ${DOMAIN}
TLS      : Yes
SNI      : ${DOMAIN}

${TROJAN_LINK}


============================================================
VLESS + WEBSOCKET + TLS
============================================================

Address    : ${DOMAIN}
Port       : 443
UUID       : ${VLESS_UUID}
Encryption : none
Network    : WebSocket
Path       : ${VLESS_PATH}
Host       : ${DOMAIN}
TLS        : Yes
SNI        : ${DOMAIN}

${VLESS_LINK}


============================================================
VMESS + WEBSOCKET + TLS
============================================================

Address : ${DOMAIN}
Port    : 443
UUID    : ${VMESS_UUID}
AlterID : 0
Security: auto
Network : WebSocket
Path    : ${VMESS_PATH}
Host    : ${DOMAIN}
TLS     : Yes
SNI     : ${DOMAIN}

${VMESS_LINK}

============================================================
INTERNAL XRAY
============================================================

Trojan : 127.0.0.1:${TROJAN_PORT}
VLESS  : 127.0.0.1:${VLESS_PORT}
VMess  : 127.0.0.1:${VMESS_PORT}

============================================================
EOF

# ============================================================
# FINAL CHECK
# ============================================================

echo
echo "============================================================"
echo " 12. FINAL CHECK"
echo "============================================================"

echo
echo "--- XRAY ---"
systemctl --no-pager --full status xray | head -20 || true

echo
echo "--- NGINX ---"
systemctl --no-pager --full status nginx | head -20 || true

echo
echo "--- LISTEN PORT ---"
ss -lntp | grep -E ':443|:80|:10001|:10002|:10003' || true

echo
echo "============================================================"
echo "              INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "DOMAIN : ${DOMAIN}"
echo
echo "Public : 443 TLS"
echo
echo
echo "TROJAN"
echo "  Password : ${TROJAN_PASSWORD}"
echo "  Path     : ${TROJAN_PATH}"
echo
echo "VLESS"
echo "  UUID     : ${VLESS_UUID}"
echo "  Path     : ${VLESS_PATH}"
echo
echo "VMESS"
echo "  UUID     : ${VMESS_UUID}"
echo "  Path     : ${VMESS_PATH}"
echo
echo "Account tersimpan:"
echo "  /root/xray-account.txt"
echo
echo "Lihat account:"
echo "  cat /root/xray-account.txt"
echo
echo "============================================================"

cat /root/xray-account.txt

INSTALLER

chmod +x /root/install-xray.sh

/root/install-xray.sh
