cat > /root/install-singbox-warp-full.sh <<'INSTALLER'
#!/bin/bash

set -Eeuo pipefail

clear

echo "============================================================"
echo " SING-BOX + NGINX + TLS - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " HIGH CONNECTION + IPV4 ONLY + BBR"
echo " GEOSITE -> SRS + CLOUDFLARE WARP"
echo " META / WHATSAPP / FACEBOOK / INSTAGRAM"
echo " MESSENGER / THREADS / BROWSERLEAKS"
echo "============================================================"
echo

# ============================================================
# 0. ROOT
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Jalankan sebagai root."
    exit 1
fi


# ============================================================
# 1. INPUT DOMAIN
# ============================================================

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


# ============================================================
# VARIABLE
# ============================================================

UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"

TROJAN_PASS="kuota_15_dec"

TROJAN_PORT="10001"
VMESS_PORT="10002"
VLESS_PORT="10003"

WARP_PORT="40000"

WORK="/root/geosite-convert"

SRS_RUNTIME="/etc/sing-box/rule-set"

export DEBIAN_FRONTEND=noninteractive


echo
echo "============================================================"
echo " DOMAIN"
echo "============================================================"
echo
echo "Domain : $DOMAIN"
echo


# ============================================================
# 2. BACKUP
# ============================================================

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"

mkdir -p "$BACKUP"

cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true
cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true


# ============================================================
# 3. TIMEZONE
# ============================================================

echo
echo "============================================================"
echo " 1. SET TIMEZONE ASIA/JAKARTA"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta

timedatectl | grep "Time zone" || true


# ============================================================
# 4. DEPENDENCY
# ============================================================

echo
echo "============================================================"
echo " 2. INSTALL DEPENDENCY"
echo "============================================================"

apt-get update

apt-get install -y \
    curl \
    wget \
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
    python3 \
    git \
    golang-go \
    lsb-release \
    iptables


# ============================================================
# 5. NODEJS + PM2
# ============================================================

echo
echo "============================================================"
echo " 3. INSTALL NODEJS 24 + PM2"
echo "============================================================"

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

npm install -g pm2

node --version || true
npm --version || true
pm2 --version || true


# ============================================================
# 6. INSTALL SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 4. INSTALL SING-BOX"
echo "============================================================"

mkdir -p /etc/apt/keyrings

curl -fsSL \
    https://sing-box.app/gpg.key \
    -o /etc/apt/keyrings/sagernet.asc

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

echo

sing-box version


# ============================================================
# 7. DISABLE IPV6
# ============================================================

echo
echo "============================================================"
echo " 5. DISABLE IPV6"
echo "============================================================"

cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF


# ============================================================
# 8. DNS
# ============================================================

echo
echo "============================================================"
echo " 6. DNS VPS"
echo "============================================================"

if [ ! -L /etc/resolv.conf ]; then

    cp -a \
        /etc/resolv.conf \
        /etc/resolv.conf.backup.$(date +%F-%H%M%S) \
        2>/dev/null || true

    cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
EOF

fi


# ============================================================
# 9. BBR + HIGH CONNECTION
# ============================================================

echo
echo "============================================================"
echo " 7. BBR + HIGH CONNECTION"
echo "============================================================"

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


# ============================================================
# 10. LIMIT
# ============================================================

echo
echo "============================================================"
echo " 8. HIGH CONNECTION LIMIT"
echo "============================================================"

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


# ============================================================
# 11. PREPARE SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 9. PREPARE SING-BOX"
echo "============================================================"

if ! id sing-box >/dev/null 2>&1; then

    useradd \
        --system \
        --home /var/lib/sing-box \
        --shell /usr/sbin/nologin \
        sing-box

fi

mkdir -p \
    /etc/sing-box \
    /etc/sing-box/rule-set \
    /var/lib/sing-box \
    /var/log/sing-box

touch /var/log/sing-box/sing-box.log

chown -R \
    sing-box:sing-box \
    /var/lib/sing-box \
    /var/log/sing-box

chmod 755 /var/log/sing-box

chmod 664 /var/log/sing-box/sing-box.log


# ============================================================
# 12. CONFIG AWAL SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 10. CONFIG AWAL SING-BOX"
echo "============================================================"

cat > /etc/sing-box/config.json <<EOF
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
      "listen_port": ${TROJAN_PORT},
      "users": [
        {
          "password": "${TROJAN_PASS}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/trojan"
      }
    },

    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${VMESS_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    },

    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "127.0.0.1",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],

  "route": {
    "rules": [
      {
        "ip_version": 6,
        "action": "reject"
      },
      {
        "action": "resolve",
        "strategy": "ipv4_only"
      }
    ]
  }
}
EOF

sing-box check -c /etc/sing-box/config.json


# ============================================================
# 13. SYSTEMD SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 11. SYSTEMD SING-BOX"
echo "============================================================"

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

    echo
    echo "ERROR: sing-box gagal aktif."

    journalctl \
        -u sing-box \
        -n 100 \
        --no-pager

    exit 1

fi


# ============================================================
# 14. NGINX GLOBAL
# ============================================================

echo
echo "============================================================"
echo " 12. CONFIG NGINX"
echo "============================================================"

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


# ============================================================
# 15. NGINX PORT 80
# ============================================================

echo
echo "============================================================"
echo " 13. NGINX PORT 80"
echo "============================================================"

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {

    listen 80 default_server;

    server_name ${DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {

        root /var/www/html;

        default_type text/plain;
    }

    location / {

        return 200 "sing-box server\n";

        add_header Content-Type text/plain;
    }
}
EOF

ln -sf \
    /etc/nginx/sites-available/singbox.conf \
    /etc/nginx/sites-enabled/singbox.conf

nginx -t

systemctl enable nginx

systemctl restart nginx


# ============================================================
# 16. SSL
# ============================================================

echo
echo "============================================================"
echo " 14. SSL LET'S ENCRYPT"
echo "============================================================"
echo
echo "Domain harus sudah mengarah ke IP VPS:"
echo "$DOMAIN"
echo

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then

    certbot certonly \
        --webroot \
        -w /var/www/html \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email

fi

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then

    echo
    echo "ERROR: Sertifikat SSL tidak ditemukan."
    echo "Pastikan DNS domain sudah mengarah ke IP VPS."

    exit 1

fi


# ============================================================
# 17. NGINX TLS 443
# ============================================================

echo
echo "============================================================"
echo " 15. NGINX TLS 443"
echo "============================================================"

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {

    listen 80 default_server;

    server_name ${DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {

        root /var/www/html;

        default_type text/plain;
    }

    location / {

        return 301 https://\$host\$request_uri;
    }
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

    location / {

        return 200 "OK\n";

        add_header Content-Type text/plain;
    }
}
EOF

nginx -t

systemctl restart nginx

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true


# ============================================================
# 18. FIREWALL
# ============================================================

echo
echo "============================================================"
echo " 16. FIREWALL"
echo "============================================================"

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true


# ============================================================
# 19. LOGROTATE
# ============================================================

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


# ============================================================
# 20. DOWNLOAD GEOSITE.DAT
# ============================================================

echo
echo "============================================================"
echo " 17. DOWNLOAD GEOSITE.DAT"
echo "============================================================"

mkdir -p "$WORK"

cd "$WORK"

rm -f geosite.dat

wget \
    --tries=5 \
    --timeout=30 \
    -O geosite.dat \
    "https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

if [ ! -s geosite.dat ]; then

    echo
    echo "ERROR: geosite.dat gagal didownload."

    exit 1

fi

echo

ls -lh geosite.dat


# ============================================================
# 21. INSTALL V2DAT DARI SOURCE
# ============================================================

echo
echo "============================================================"
echo " 18. INSTALL V2DAT DARI SOURCE"
echo "============================================================"

if ! command -v v2dat >/dev/null 2>&1; then

    rm -rf /tmp/v2dat

    git clone \
        --depth 1 \
        https://github.com/urlesistiana/v2dat.git \
        /tmp/v2dat

    if [ ! -f /tmp/v2dat/go.mod ]; then

        echo
        echo "ERROR: Source v2dat gagal didownload."

        exit 1

    fi

    cd /tmp/v2dat

    echo
    echo "Go version:"
    go version

    echo
    echo "Download dependency..."

    go mod download

    echo
    echo "Build v2dat..."

    go build \
        -o /usr/local/bin/v2dat \
        .

    chmod +x /usr/local/bin/v2dat

fi

if ! command -v v2dat >/dev/null 2>&1; then

    echo
    echo "ERROR: v2dat gagal diinstall."

    exit 1

fi

echo
echo "============================================================"
echo " V2DAT"
echo "============================================================"
echo

v2dat --help

echo
echo "============================================================"
echo " V2DAT GEOSITE HELP"
echo "============================================================"
echo

v2dat unpack geosite --help


# ============================================================
# 22. EXTRACT SEMUA GEOSITE
#
# PERBAIKAN:
# v2dat versi ini menggunakan:
#
# -o / --out
#
# BUKAN -d
# ============================================================

echo
echo "============================================================"
echo " 19. EXTRACT SEMUA KATEGORI GEOSITE"
echo "============================================================"

cd "$WORK"

rm -rf "$WORK/txt"

mkdir -p "$WORK/txt"

echo
echo "Menggunakan:"
echo
echo "v2dat unpack geosite -o $WORK/txt $WORK/geosite.dat"
echo

v2dat unpack geosite \
    -o "$WORK/txt" \
    "$WORK/geosite.dat"


# ============================================================
# HITUNG TXT
# ============================================================

TXT_COUNT="$(
    find "$WORK/txt" \
        -type f \
        -name '*.txt' \
        | wc -l
)"

echo
echo "============================================================"
echo " HASIL EXTRACT"
echo "============================================================"
echo
echo "Jumlah kategori TXT : $TXT_COUNT"
echo

if [ "$TXT_COUNT" -eq 0 ]; then

    echo
    echo "ERROR: Tidak ada kategori geosite yang berhasil diextract."

    echo
    echo "Isi directory:"
    ls -lah "$WORK/txt" || true

    exit 1

fi

echo
echo "Contoh kategori:"
echo

find "$WORK/txt" \
    -type f \
    -name '*.txt' \
    -printf '%f\n' \
    | sort \
    | head -30


# ============================================================
# 23. CONVERT TXT -> JSON -> SRS
# ============================================================

echo
echo "============================================================"
echo " 20. CONVERT SEMUA KATEGORI KE SRS"
echo "============================================================"

rm -rf "$WORK/json"
rm -rf "$WORK/srs"

mkdir -p "$WORK/json"
mkdir -p "$WORK/srs"

SUCCESS=0
FAILED=0


while IFS= read -r -d '' FILE
do

    BASE="$(basename "$FILE" .txt)"

    NAME="${BASE#geosite_}"
    NAME="${NAME#geosite-}"

    JSON="$WORK/json/${NAME}.json"
    SRS="$WORK/srs/${NAME}.srs"

    echo
    echo "Convert: $NAME"

    python3 \
        - "$FILE" "$JSON" <<'PY'

import sys
import json


src = sys.argv[1]
dst = sys.argv[2]


domain = set()
domain_suffix = set()
domain_keyword = set()
domain_regex = set()


with open(
    src,
    "r",
    encoding="utf-8",
    errors="ignore"
) as f:

    for raw in f:

        line = raw.strip()

        if not line:
            continue

        if line.startswith("#"):
            continue


        #
        # Hapus attribute:
        #
        # contoh:
        #
        # google.com @cn
        #
        if " @" in line:

            line = line.split(
                " @",
                1
            )[0].strip()


        if not line:
            continue


        #
        # full:
        #
        if line.startswith("full:"):

            value = line[5:].strip()

            if value:
                domain.add(value)


        #
        # domain:
        #
        elif line.startswith("domain:"):

            value = line[7:].strip()

            if value:
                domain_suffix.add(value)


        #
        # keyword:
        #
        elif line.startswith("keyword:"):

            value = line[8:].strip()

            if value:
                domain_keyword.add(value)


        #
        # regexp:
        #
        elif line.startswith("regexp:"):

            value = line[7:].strip()

            if value:
                domain_regex.add(value)


        #
        # v2dat dapat menghasilkan domain biasa
        #
        else:

            domain_suffix.add(line)


rule = {}


if domain:

    rule["domain"] = sorted(domain)


if domain_suffix:

    rule["domain_suffix"] = sorted(domain_suffix)


if domain_keyword:

    rule["domain_keyword"] = sorted(domain_keyword)


if domain_regex:

    rule["domain_regex"] = sorted(domain_regex)


result = {

    "version": 3,

    "rules": [
        rule
    ] if rule else []
}


with open(
    dst,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        result,
        f,
        ensure_ascii=False,
        separators=(",", ":")
    )

PY


    if sing-box rule-set compile \
        "$JSON" \
        -o "$SRS"
    then

        echo "OK   : ${NAME}.srs"

        SUCCESS=$((SUCCESS + 1))

    else

        echo "FAIL : ${NAME}.srs"

        FAILED=$((FAILED + 1))

        rm -f "$SRS"

    fi


done < <(
    find "$WORK/txt" \
        -type f \
        -name '*.txt' \
        -print0
)


# ============================================================
# HITUNG SRS
# ============================================================

SRS_COUNT="$(
    find "$WORK/srs" \
        -type f \
        -name '*.srs' \
        | wc -l
)"

echo
echo "============================================================"
echo " HASIL CONVERT GEOSITE"
echo "============================================================"
echo
echo "Kategori TXT : $TXT_COUNT"
echo "SRS sukses   : $SUCCESS"
echo "SRS gagal    : $FAILED"
echo "File SRS     : $SRS_COUNT"
echo
echo "Lokasi:"
echo
echo "$WORK/srs/"
echo


if [ "$SRS_COUNT" -eq 0 ]; then

    echo
    echo "ERROR: Tidak ada SRS yang berhasil dibuat."

    exit 1

fi


# ============================================================
# 24. TAMPILKAN SEMUA KATEGORI
# ============================================================

echo
echo "============================================================"
echo " 21. SEMUA KATEGORI SRS"
echo "============================================================"
echo

find "$WORK/srs" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '%f\n' \
    | sort


# ============================================================
# 25. CARI META
# ============================================================

echo
echo "============================================================"
echo " 22. KATEGORI META YANG DITEMUKAN"
echo "============================================================"
echo

find "$WORK/srs" \
    -maxdepth 1 \
    -type f \
    \( \
        -iname '*meta*.srs' \
        -o -iname '*facebook*.srs' \
        -o -iname '*instagram*.srs' \
        -o -iname '*whatsapp*.srs' \
        -o -iname '*messenger*.srs' \
        -o -iname '*threads*.srs' \
    \) \
    -printf '%f\n' \
    | sort \
    || true


# ============================================================
# 26. CLOUDFLARE WARP
# ============================================================

echo
echo "============================================================"
echo " 23. INSTALL CLOUDFLARE WARP - SSH SAFE"
echo "============================================================"

SSH_CLIENT_IP="$(
    echo "${SSH_CLIENT:-}" \
    | awk '{print $1}'
)"

SSH_SERVER_IP="$(
    echo "${SSH_CONNECTION:-}" \
    | awk '{print $3}'
)"

echo
echo "SSH Client IP : ${SSH_CLIENT_IP:-unknown}"
echo "VPS IP        : ${SSH_SERVER_IP:-unknown}"
echo
echo "Default route sebelum WARP:"
echo

ip route show default


# ============================================================
# 27. CLOUDFLARE REPO
# ============================================================

echo
echo "============================================================"
echo " 24. CLOUDFLARE REPOSITORY"
echo "============================================================"

install \
    -d \
    -m 0755 \
    /usr/share/keyrings

curl -fsSL \
    https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg \
        --yes \
        --dearmor \
        -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg


CODENAME="$(
    . /etc/os-release
    echo "${VERSION_CODENAME}"
)"


echo
echo "OS codename: $CODENAME"
echo


cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main
EOF


apt-get update

apt-get install -y cloudflare-warp


systemctl enable warp-svc

systemctl restart warp-svc

sleep 3


echo

systemctl \
    --no-pager \
    --full \
    status warp-svc \
    | head -20 \
    || true


# ============================================================
# 28. REGISTER WARP
# ============================================================

echo
echo "============================================================"
echo " 25. REGISTER WARP"
echo "============================================================"

warp-cli disconnect >/dev/null 2>&1 || true

warp-cli registration delete >/dev/null 2>&1 || true


#
# || true digunakan karena command yes dapat menerima SIGPIPE
# setelah warp-cli selesai membaca input.
#
yes | warp-cli registration new || true


sleep 3


echo

warp-cli registration show || true


# ============================================================
# 29. WARP PROXY MODE
# ============================================================

echo
echo "============================================================"
echo " 26. WARP PROXY MODE"
echo "============================================================"
echo
echo "WARP hanya digunakan sebagai local proxy."
echo
echo "Default route VPS TIDAK diganti."
echo
echo "SSH tetap memakai IP asli VPS."
echo


if ! warp-cli mode proxy; then

    echo
    echo "ERROR: Gagal mengaktifkan WARP proxy mode."
    echo

    warp-cli mode --help || true

    exit 1

fi


sleep 1


# ============================================================
# 30. WARP PORT
# ============================================================

echo
echo "============================================================"
echo " 27. SET WARP SOCKS5 PORT"
echo "============================================================"

warp-cli proxy port "$WARP_PORT"


# ============================================================
# 31. CONNECT WARP
# ============================================================

echo
echo "============================================================"
echo " 28. CONNECT WARP"
echo "============================================================"

warp-cli connect

sleep 5


echo
echo "============================================================"
echo " WARP STATUS"
echo "============================================================"
echo

warp-cli status || true


# ============================================================
# 32. DEFAULT ROUTE
# ============================================================

echo
echo "============================================================"
echo " 29. DEFAULT ROUTE SETELAH WARP"
echo "============================================================"
echo

ip route show default


# ============================================================
# 33. TEST IP VPS
# ============================================================

echo
echo "============================================================"
echo " 30. IP ASLI VPS"
echo "============================================================"
echo

curl \
    -4 \
    --max-time 15 \
    https://api.ipify.org \
    || true

echo


# ============================================================
# 34. TEST WARP
# ============================================================

echo
echo "============================================================"
echo " 31. TEST WARP SOCKS5"
echo "============================================================"
echo

curl \
    --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
    --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace \
    || true

echo


# ============================================================
# 35. TEST IP WARP
# ============================================================

echo
echo "============================================================"
echo " 32. IP WARP"
echo "============================================================"
echo

curl \
    --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
    --max-time 20 \
    https://api.ipify.org \
    || true

echo


# ============================================================
# 36. PORT WARP
# ============================================================

echo
echo "============================================================"
echo " 33. CEK PORT WARP"
echo "============================================================"
echo

ss -lntp \
    | grep ":${WARP_PORT}" \
    || true


# ============================================================
# 37. PREPARE ACTIVE SRS
# ============================================================

echo
echo "============================================================"
echo " 34. PREPARE ACTIVE RULE-SET"
echo "============================================================"

rm -rf "$SRS_RUNTIME"

mkdir -p "$SRS_RUNTIME"

chmod 755 "$SRS_RUNTIME"


# ============================================================
# 38. GENERATE ROUTING CONFIG
# ============================================================

echo
echo "============================================================"
echo " 35. ROUTING META MELALUI WARP"
echo "============================================================"


python3 \
    - "$WORK/srs" "$SRS_RUNTIME" "$WARP_PORT" <<'PY'

import os
import sys
import json
import glob
import shutil
import re


SRS_SOURCE = sys.argv[1]

SRS_RUNTIME = sys.argv[2]

WARP_PORT = int(sys.argv[3])

CONFIG = "/etc/sing-box/config.json"


# ============================================================
# LOAD CONFIG
# ============================================================

with open(
    CONFIG,
    "r",
    encoding="utf-8"
) as f:

    cfg = json.load(f)


# ============================================================
# OUTBOUND WARP
# ============================================================

outbounds = cfg.setdefault(
    "outbounds",
    []
)


#
# Hapus outbound WARP lama apabila script dijalankan ulang
#
outbounds[:] = [

    outbound

    for outbound in outbounds

    if outbound.get("tag") != "warp"

]


outbounds.append({

    "type": "socks",

    "tag": "warp",

    "server": "127.0.0.1",

    "server_port": WARP_PORT

})


# ============================================================
# CARI KATEGORI META
# ============================================================

wanted_words = (

    "meta",

    "facebook",

    "instagram",

    "whatsapp",

    "messenger",

    "threads",

)


all_srs = sorted(

    glob.glob(

        os.path.join(

            SRS_SOURCE,

            "*.srs"

        )

    )

)


selected = []


for source in all_srs:

    filename = os.path.basename(
        source
    )

    lower = filename.lower()


    tokens = [

        x

        for x in re.split(
            r"[^a-z0-9]+",
            lower
        )

        if x

    ]


    matched = False


    for wanted in wanted_words:


        if wanted in tokens:

            matched = True

            break


        if lower == wanted + ".srs":

            matched = True

            break


        if lower.startswith(
            wanted + "-"
        ):

            matched = True

            break


        if lower.startswith(
            wanted + "_"
        ):

            matched = True

            break


    if matched:

        selected.append(
            source
        )


# ============================================================
# COPY SRS KE /etc/sing-box/rule-set
# ============================================================

rule_sets = []

rule_tags = []


for source in selected:


    filename = os.path.basename(
        source
    )


    destination = os.path.join(

        SRS_RUNTIME,

        filename

    )


    shutil.copy2(

        source,

        destination

    )


    os.chmod(

        destination,

        0o644

    )


    name = os.path.splitext(
        filename
    )[0]


    safe_name = re.sub(

        r"[^a-zA-Z0-9_-]+",

        "-",

        name

    )


    tag = "geosite-" + safe_name


    rule_sets.append({

        "type": "local",

        "tag": tag,

        "format": "binary",

        "path": destination

    })


    rule_tags.append(
        tag
    )


# ============================================================
# ROUTE
# ============================================================

route = cfg.setdefault(

    "route",

    {}

)


if rule_sets:

    route["rule_set"] = rule_sets

else:

    route.pop(
        "rule_set",
        None
    )


# ============================================================
# DOMAIN FALLBACK
# ============================================================

meta_domains = [

    #
    # FACEBOOK
    #

    "facebook.com",

    "facebook.net",

    "facebook.org",

    "facebookmail.com",

    "fb.com",

    "fb.me",

    "fb.gg",

    "fb.watch",

    "fbcdn.net",

    "fbcdn.com",

    "fbsbx.com",


    #
    # MESSENGER
    #

    "messenger.com",

    "m.me",


    #
    # INSTAGRAM
    #

    "instagram.com",

    "cdninstagram.com",


    #
    # WHATSAPP
    #

    "whatsapp.com",

    "whatsapp.net",


    #
    # THREADS
    #

    "threads.net",

    "threads.com",


    #
    # META
    #

    "meta.com",

    "meta.ai",

    "metacareers.com",

    "metastatus.com",


    #
    # BROWSERLEAKS
    #

    "browserleaks.com"

]


# ============================================================
# RULES
# ============================================================

rules = []


#
# IPv6 tetap reject
#
rules.append({

    "ip_version": 6,

    "action": "reject"

})


#
# SRS META
#
if rule_tags:

    rules.append({

        "rule_set": rule_tags,

        "action": "route",

        "outbound": "warp"

    })


#
# DOMAIN FALLBACK
#
rules.append({

    "domain_suffix": meta_domains,

    "action": "route",

    "outbound": "warp"

})


#
# IPv4 only
#
rules.append({

    "action": "resolve",

    "strategy": "ipv4_only"

})


route["rules"] = rules


#
# Traffic selain Meta tetap direct
#
route["final"] = "direct"


# ============================================================
# SAVE CONFIG
# ============================================================

with open(

    CONFIG,

    "w",

    encoding="utf-8"

) as f:


    json.dump(

        cfg,

        f,

        ensure_ascii=False,

        indent=2

    )


# ============================================================
# OUTPUT
# ============================================================

print()

print(
    "============================================================"
)

print(
    "SRS YANG DIGUNAKAN UNTUK WARP"
)

print(
    "============================================================"
)


if selected:


    for source in selected:

        print(
            os.path.basename(source)
        )


else:


    print(
        "Tidak ditemukan kategori SRS Meta khusus."
    )


    print(
        "Routing domain fallback tetap aktif."
    )


print()

print(
    "Total SRS Meta:",
    len(selected)
)

print()

print(
    "Rule-set runtime:",
    SRS_RUNTIME
)

PY


# ============================================================
# 39. PERMISSION RULE-SET
# ============================================================

chown -R root:root "$SRS_RUNTIME"

chmod 755 "$SRS_RUNTIME"

find "$SRS_RUNTIME" \
    -type f \
    -name '*.srs' \
    -exec chmod 644 {} \;


# ============================================================
# 40. CHECK FINAL CONFIG
# ============================================================

echo
echo "============================================================"
echo " 36. CEK CONFIG ROUTING WARP"
echo "============================================================"
echo


if ! sing-box check \
    -c /etc/sing-box/config.json
then

    echo
    echo "============================================================"
    echo " ERROR CONFIG SING-BOX"
    echo "============================================================"
    echo

    cat /etc/sing-box/config.json

    exit 1

fi


echo
echo "Config sing-box VALID."


# ============================================================
# 41. RESTART
# ============================================================

echo
echo "============================================================"
echo " 37. RESTART SING-BOX"
echo "============================================================"

systemctl restart sing-box

sleep 3


if ! systemctl is-active --quiet sing-box
then

    echo
    echo "ERROR: sing-box gagal start."
    echo

    journalctl \
        -u sing-box \
        -n 100 \
        --no-pager

    exit 1

fi


# ============================================================
# 42. STATUS SERVICE
# ============================================================

echo
echo "============================================================"
echo " 38. STATUS SERVICE"
echo "============================================================"
echo


echo -n "sing-box : "

systemctl is-active sing-box || true


echo -n "nginx    : "

systemctl is-active nginx || true


echo -n "warp-svc : "

systemctl is-active warp-svc || true


# ============================================================
# 43. PORT
# ============================================================

echo
echo "============================================================"
echo " 39. PORT"
echo "============================================================"
echo


ss -lntp \
    | grep -E \
    ':80 |:443 |:10001|:10002|:10003|:40000' \
    || true


# ============================================================
# 44. BBR
# ============================================================

echo
echo "============================================================"
echo " 40. BBR"
echo "============================================================"
echo


sysctl \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    || true


# ============================================================
# 45. IPV6
# ============================================================

echo
echo "============================================================"
echo " 41. IPV6"
echo "============================================================"
echo


sysctl \
    net.ipv6.conf.all.disable_ipv6 \
    || true


# ============================================================
# 46. FINAL CONFIG TEST
# ============================================================

echo
echo "============================================================"
echo " 42. FINAL CONFIG TEST"
echo "============================================================"
echo


sing-box check \
    -c /etc/sing-box/config.json


nginx -t


# ============================================================
# 47. WARP TRACE
# ============================================================

echo
echo "============================================================"
echo " 43. WARP TRACE"
echo "============================================================"
echo


curl \
    --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
    --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace \
    || true


echo


# ============================================================
# 48. IP VPS
# ============================================================

echo
echo "============================================================"
echo " 44. IP ASLI VPS"
echo "============================================================"
echo


ORIGINAL_IP="$(
    curl \
        -4 \
        --silent \
        --max-time 15 \
        https://api.ipify.org \
        || true
)"


echo "${ORIGINAL_IP:-GAGAL}"


# ============================================================
# 49. IP WARP
# ============================================================

echo
echo "============================================================"
echo " 45. IP WARP"
echo "============================================================"
echo


WARP_IP="$(
    curl \
        --silent \
        --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
        --max-time 20 \
        https://api.ipify.org \
        || true
)"


echo "${WARP_IP:-GAGAL}"


# ============================================================
# 50. LIST ACTIVE SRS
# ============================================================

echo
echo "============================================================"
echo " 46. ACTIVE SRS"
echo "============================================================"
echo


echo "Semua SRS : $SRS_COUNT"

echo
echo "SRS Meta aktif:"
echo


find "$SRS_RUNTIME" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '%f\n' \
    | sort \
    || true


# ============================================================
# 51. DEFAULT ROUTE FINAL
# ============================================================

echo
echo "============================================================"
echo " 47. DEFAULT ROUTE VPS"
echo "============================================================"
echo


ip route show default


# ============================================================
# FINAL
# ============================================================

echo
echo
echo "============================================================"
echo "              INSTALLASI SELESAI"
echo "============================================================"
echo

echo "Domain      : $DOMAIN"

echo

echo "Trojan Pass : $TROJAN_PASS"
echo "UUID        : $UUID"

echo

echo "Trojan WS   : /trojan"
echo "VMess WS    : /vmess"
echo "VLESS WS    : /vless"

echo

echo "Port TLS    : 443"

echo

echo "Trojan      : 127.0.0.1:${TROJAN_PORT}"
echo "VMess       : 127.0.0.1:${VMESS_PORT}"
echo "VLESS       : 127.0.0.1:${VLESS_PORT}"

echo

echo "IPv6        : OFF"
echo "IPv4        : ONLY"

echo

echo "WARP SOCKS5 : 127.0.0.1:${WARP_PORT}"

echo

echo "GEOSITE DAT : $WORK/geosite.dat"

echo

echo "TXT         : $WORK/txt/"
echo "JSON        : $WORK/json/"
echo "SEMUA SRS   : $WORK/srs/"
echo "SRS ACTIVE  : $SRS_RUNTIME/"

echo

echo "============================================================"
echo " ROUTING VIA CLOUDFLARE WARP"
echo "============================================================"
echo

echo " - Meta"
echo " - WhatsApp"
echo " - Facebook"
echo " - Instagram"
echo " - Messenger"
echo " - Threads"
echo " - browserleaks.com"

echo

echo "============================================================"
echo " TRAFFIC LAIN"
echo "============================================================"
echo

echo " - DIRECT"
echo " - IP asli VPS"

echo

echo "============================================================"
echo " SSH VPS"
echo "============================================================"
echo

echo "SSH tetap menggunakan default route/IP asli VPS."
echo "WARP hanya local SOCKS5 proxy."

echo

echo "============================================================"
echo " IP"
echo "============================================================"
echo

echo "IP VPS  : ${ORIGINAL_IP:-GAGAL}"
echo "IP WARP : ${WARP_IP:-GAGAL}"

echo

echo "============================================================"
echo " STATUS WARP"
echo "============================================================"
echo

warp-cli status || true

echo

echo "============================================================"
echo " STATUS SING-BOX"
echo "============================================================"
echo


systemctl \
    --no-pager \
    --full \
    status sing-box \
    | head -20 \
    || true


echo
echo "============================================================"
echo " STATUS NGINX"
echo "============================================================"
echo


systemctl \
    --no-pager \
    --full \
    status nginx \
    | head -15 \
    || true


echo
echo "============================================================"
echo " COMMAND TEST"
echo "============================================================"
echo

echo "Test IP VPS:"
echo
echo "curl -4 https://api.ipify.org"

echo

echo "Test WARP:"
echo
echo "curl --proxy socks5h://127.0.0.1:${WARP_PORT} https://www.cloudflare.com/cdn-cgi/trace"

echo

echo "Test IP WARP:"
echo
echo "curl --proxy socks5h://127.0.0.1:${WARP_PORT} https://api.ipify.org"

echo

echo "Cek config:"
echo
echo "sing-box check -c /etc/sing-box/config.json"

echo

echo "Log sing-box:"
echo
echo "journalctl -u sing-box -f"

echo

echo "Restart:"
echo
echo "systemctl restart sing-box nginx warp-svc"

echo

echo "Lihat semua SRS:"
echo
echo "ls -lah $WORK/srs/"

echo

echo "Lihat SRS Meta aktif:"
echo
echo "ls -lah $SRS_RUNTIME/"

echo

echo "============================================================"
echo "                   SELESAI"
echo "============================================================"

INSTALLER

chmod +x /root/install-singbox-warp-full.sh

/root/install-singbox-warp-full.sh
