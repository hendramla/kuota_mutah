cat > /root/install-singbox-warp.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail

clear

echo "============================================================"
echo " SING-BOX + NGINX + TLS + CLOUDFLARE WARP - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " GEOSITE.DAT -> SRS + META VIA WARP"
echo " SSH / VPS DEFAULT ROUTE TETAP DIRECT"
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

GEOSITE_URL="https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

export DEBIAN_FRONTEND=noninteractive

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP"

cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true
cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true

timedatectl set-timezone Asia/Jakarta


echo
echo "============================================================"
echo " 1. INSTALL PACKAGE"
echo "============================================================"

apt-get update

apt-get install -y \
    curl wget unzip zip socat ca-certificates gnupg openssl \
    nginx certbot ufw jq mtr-tiny dnsutils \
    iproute2 net-tools procps git golang-go


echo
echo "============================================================"
echo " 2. NODE.JS + PM2"
echo "============================================================"

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

npm install -g pm2


echo
echo "============================================================"
echo " 3. INSTALL SING-BOX"
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
echo "============================================================"
echo " 4. INSTALL CLOUDFLARE WARP"
echo "============================================================"

install -d -m 0755 /usr/share/keyrings

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --dearmor \
    > /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"

cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main
EOF

apt-get update
apt-get install -y cloudflare-warp

systemctl enable --now warp-svc

sleep 3


echo
echo "============================================================"
echo " 5. WARP PROXY MODE - SSH AMAN"
echo "============================================================"

# Tidak menggunakan WARP sebagai default network route.
# Jadi SSH, Nginx, apt, dll tetap memakai IP VPS asli.
#
# Hanya sing-box yang mengirim traffic tertentu ke
# SOCKS5 WARP lokal 127.0.0.1:40000.

warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
warp-cli --accept-tos registration delete >/dev/null 2>&1 || true

warp-cli --accept-tos registration new || true

# Proxy mode WARP
warp-cli --accept-tos mode proxy

# Port proxy lokal
warp-cli --accept-tos proxy port 40000

warp-cli --accept-tos connect

sleep 5

echo
echo "===== WARP SETTINGS ====="
warp-cli --accept-tos settings || true

echo
echo "===== WARP STATUS ====="
warp-cli --accept-tos status || true


echo
echo "============================================================"
echo " 6. TEST SOCKS5 WARP"
echo "============================================================"

WARP_TEST=""

for i in {1..10}; do

    WARP_TEST="$(
        curl -4 \
        --max-time 10 \
        --socks5-hostname 127.0.0.1:40000 \
        https://www.cloudflare.com/cdn-cgi/trace \
        2>/dev/null || true
    )"

    if echo "$WARP_TEST" | grep -q '^warp=on'; then
        break
    fi

    sleep 2
done

echo "$WARP_TEST"

if ! echo "$WARP_TEST" | grep -q '^warp=on'; then
    echo
    echo "WARNING: WARP belum menunjukkan warp=on."
    echo "Installer tetap dilanjutkan."
    echo
fi


echo
echo "============================================================"
echo " 7. IPV6 OFF + NETWORK TUNING"
echo "============================================================"

cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF


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


echo
echo "============================================================"
echo " 8. DOWNLOAD GEOSITE.DAT"
echo "============================================================"

mkdir -p /etc/sing-box/geosite
mkdir -p /etc/sing-box/rules
mkdir -p /root/geosite-convert

cd /root/geosite-convert

wget -O geosite.dat "$GEOSITE_URL"

if [ ! -s geosite.dat ]; then
    echo "ERROR: geosite.dat gagal didownload."
    exit 1
fi

ls -lh geosite.dat


echo
echo "============================================================"
echo " 9. INSTALL METACUBEX GEO"
echo "============================================================"

rm -rf /tmp/metacubex-geo

git clone \
    --depth=1 \
    https://github.com/MetaCubeX/geo.git \
    /tmp/metacubex-geo

cd /tmp/metacubex-geo

go build -o /usr/local/bin/geo .

chmod +x /usr/local/bin/geo

echo
/usr/local/bin/geo --help || true


echo
echo "============================================================"
echo " 10. CONVERT SEMUA GEOSITE KE FORMAT SING"
echo "============================================================"

cd /root/geosite-convert

rm -rf sing-geosite
mkdir -p sing-geosite

/usr/local/bin/geo convert site \
    -i v2ray \
    -o sing \
    -f sing-geosite \
    ./geosite.dat


echo
echo "============================================================"
echo " 11. COMPILE SEMUA KATEGORI MENJADI .SRS"
echo "============================================================"

RULE_SRC=""

if [ -d sing-geosite ]; then
    RULE_SRC="sing-geosite"
fi

if [ -z "$RULE_SRC" ]; then
    echo "ERROR: Folder hasil convert GeoSite tidak ditemukan."
    find /root/geosite-convert -maxdepth 3 -type f | head -100
    exit 1
fi


find "$RULE_SRC" -type f -name '*.json' -print0 |
while IFS= read -r -d '' JSON_FILE; do

    BASE="$(basename "$JSON_FILE" .json)"

    OUT="/etc/sing-box/rules/${BASE}.srs"

    echo "[SRS] ${BASE}"

    sing-box rule-set compile \
        --output "$OUT" \
        "$JSON_FILE"

done


SRS_TOTAL="$(
    find /etc/sing-box/rules \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    | wc -l
)"

echo
echo "TOTAL SRS: ${SRS_TOTAL}"

if [ "$SRS_TOTAL" -eq 0 ]; then
    echo "ERROR: Tidak ada file .srs yang berhasil dibuat."
    exit 1
fi


echo
echo "============================================================"
echo " 12. CARI KATEGORI META"
echo "============================================================"

ls -1 /etc/sing-box/rules \
    | grep -Ei \
    '(^|[-_])(meta|facebook|instagram|whatsapp|messenger|threads)([-_]|\.|$)' \
    || true


echo
echo "============================================================"
echo " 13. BUAT RULESET META GABUNGAN"
echo "============================================================"

# Karena nama kategori dalam setiap geosite.dat bisa berbeda,
# installer mengambil semua kategori yang namanya berkaitan
# dengan Meta / Facebook / WhatsApp / Instagram /
# Messenger / Threads.

MATCHED_META="$(find /etc/sing-box/rules \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '%f\n' \
    | grep -Ei \
    '(^|[-_])(meta|facebook|instagram|whatsapp|messenger|threads)([-_]|\.|$)' \
    || true)"


# Fallback domain manual penting.
# Jadi browserleaks.com + layanan Meta tetap masuk WARP
# meskipun geosite tertentu tidak memiliki kategori tertentu.

cat > /etc/sing-box/rules/meta-manual.json <<'EOF'
{
  "version": 3,
  "rules": [
    {
      "domain_suffix": [
        "facebook.com",
        "facebook.net",
        "fb.com",
        "fbcdn.net",
        "fbsbx.com",
        "messenger.com",
        "m.me",
        "instagram.com",
        "cdninstagram.com",
        "whatsapp.com",
        "whatsapp.net",
        "threads.net",
        "threads.com",
        "meta.com",
        "metacareers.com",
        "metastatus.com",
        "browserleaks.com"
      ]
    }
  ]
}
EOF

sing-box rule-set compile \
    --output /etc/sing-box/rules/meta-manual.srs \
    /etc/sing-box/rules/meta-manual.json


echo
echo "============================================================"
echo " 14. CREATE SING-BOX CONFIG"
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
    /var/lib/sing-box \
    /var/log/sing-box

touch /var/log/sing-box/sing-box.log

chown -R \
    sing-box:sing-box \
    /var/lib/sing-box \
    /var/log/sing-box

chmod 755 /var/log/sing-box
chmod 664 /var/log/sing-box/sing-box.log

chmod 755 /etc/sing-box
chmod 755 /etc/sing-box/rules
chmod 644 /etc/sing-box/rules/*.srs


RULESET_JSON=""

RULESET_TAGS=""

FIRST=1

while IFS= read -r FILE; do

    BASE="$(basename "$FILE" .srs)"

    TAG="$(echo "$BASE" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9._-]/-/g')"

    # Semua .srs tetap didaftarkan ke sing-box.
    # Jadi seluruh kategori hasil geosite tersedia.

    if [ "$FIRST" -eq 1 ]; then
        FIRST=0
    else
        RULESET_JSON+=","
    fi

    RULESET_JSON+="
    {
      \"type\": \"local\",
      \"tag\": \"geo-${TAG}\",
      \"format\": \"binary\",
      \"path\": \"${FILE}\"
    }"


    if echo "$TAG" | grep -Eqi \
        '(^|[-_.])(meta|facebook|instagram|whatsapp|messenger|threads)([-_.]|$)'
    then

        if [ -z "$RULESET_TAGS" ]; then
            RULESET_TAGS="\"geo-${TAG}\""
        else
            RULESET_TAGS+=",\"geo-${TAG}\""
        fi
    fi

done < <(
    find /etc/sing-box/rules \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    ! -name 'meta-manual.srs' \
    | sort
)


# meta-manual selalu dimasukkan.

if [ -n "$RULESET_JSON" ]; then
    RULESET_JSON+=","
fi

RULESET_JSON+="
    {
      \"type\": \"local\",
      \"tag\": \"meta-manual\",
      \"format\": \"binary\",
      \"path\": \"/etc/sing-box/rules/meta-manual.srs\"
    }"


if [ -n "$RULESET_TAGS" ]; then
    RULESET_TAGS+=",\"meta-manual\""
else
    RULESET_TAGS="\"meta-manual\""
fi


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
    },

    {
      "type": "socks",
      "tag": "warp",
      "server": "127.0.0.1",
      "server_port": 40000,
      "version": "5"
    }
  ],

  "route": {

    "rule_set": [
${RULESET_JSON}
    ],

    "rules": [

      {
        "ip_version": 6,
        "action": "reject"
      },

      {
        "domain_suffix": [
          "browserleaks.com"
        ],
        "action": "route",
        "outbound": "warp"
      },

      {
        "rule_set": [
          ${RULESET_TAGS}
        ],
        "action": "route",
        "outbound": "warp"
      },

      {
        "action": "resolve",
        "strategy": "ipv4_only"
      }
    ],

    "final": "direct"
  }
}
EOF


echo
echo "============================================================"
echo " 15. CHECK SING-BOX CONFIG"
echo "============================================================"

/usr/bin/sing-box check \
    -c /etc/sing-box/config.json


echo
echo "============================================================"
echo " 16. SYSTEMD SING-BOX"
echo "============================================================"

systemctl stop sing-box 2>/dev/null || true


cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box Proxy Service
After=network-online.target warp-svc.service
Wants=network-online.target
Requires=warp-svc.service

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

sleep 3


if ! systemctl is-active --quiet sing-box; then

    journalctl \
        -u sing-box \
        -n 150 \
        --no-pager

    exit 1
fi


echo
echo "============================================================"
echo " 17. NGINX"
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


echo
echo "============================================================"
echo " 18. TLS LET'S ENCRYPT"
echo "============================================================"


if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then

    certbot certonly \
        --webroot \
        -w /var/www/html \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email
fi


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


    ssl_certificate \
        /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;

    ssl_certificate_key \
        /etc/letsencrypt/live/${DOMAIN}/privkey.pem;


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


echo
echo "============================================================"
echo " 19. FIREWALL"
echo "============================================================"

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true


echo
echo "============================================================"
echo " 20. LOGROTATE"
echo "============================================================"


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


echo
echo "============================================================"
echo " 21. FINAL RESTART"
echo "============================================================"

systemctl daemon-reload

systemctl restart warp-svc

sleep 2

warp-cli --accept-tos connect || true

sleep 3

systemctl restart sing-box

systemctl restart nginx

sleep 3


echo
echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"

echo "Domain       : $DOMAIN"
echo "Trojan Pass  : $TROJAN_PASS"
echo "UUID         : $UUID"

echo
echo "Trojan WS    : /trojan"
echo "VMess WS     : /vmess"
echo "VLESS WS     : /vless"

echo
echo "TLS Port     : 443"

echo
echo "WARP Mode    : LOCAL SOCKS5"
echo "WARP Proxy   : 127.0.0.1:40000"

echo
echo "SSH          : DIRECT / IP VPS ASLI"
echo "Default      : DIRECT"

echo
echo "WARP ROUTE:"
echo " - Meta"
echo " - Facebook"
echo " - Instagram"
echo " - WhatsApp"
echo " - Messenger"
echo " - Threads"
echo " - browserleaks.com"

echo
echo "IPv6         : OFF"
echo "IPv4         : ONLY"

echo
echo "SRS Total    : $(find /etc/sing-box/rules -type f -name '*.srs' | wc -l)"

echo "============================================================"


echo
echo "===== STATUS SERVICE ====="

systemctl is-active \
    sing-box \
    nginx \
    warp-svc \
    || true


echo
echo "===== PORT ====="

ss -lntp \
    | grep -E \
    ':22 |:80 |:443 |:40000|:10001|:10002|:10003' \
    || true


echo
echo "===== WARP ====="

warp-cli --accept-tos status || true


echo
echo "===== WARP IP ====="

curl -4 \
    --max-time 15 \
    --socks5-hostname 127.0.0.1:40000 \
    https://www.cloudflare.com/cdn-cgi/trace \
    2>/dev/null \
    | grep -E '^(ip|warp|colo)=' \
    || true


echo
echo "===== VPS DIRECT IP ====="

curl -4 \
    --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace \
    2>/dev/null \
    | grep -E '^(ip|warp|colo)=' \
    || true


echo
echo "===== META SRS ====="

find /etc/sing-box/rules \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '%f\n' \
    | grep -Ei \
    'meta|facebook|instagram|whatsapp|messenger|threads' \
    || true


echo
echo "===== BBR ====="

sysctl \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    || true


echo
echo "===== IPV6 ====="

sysctl \
    net.ipv6.conf.all.disable_ipv6 \
    || true


echo
echo "===== TEST CONFIG ====="

sing-box check \
    -c /etc/sing-box/config.json

nginx -t


echo
echo "============================================================"
echo " SELESAI"
echo "============================================================"
SCRIPT

chmod +x /root/install-singbox-warp.sh && /root/install-singbox-warp.sh
