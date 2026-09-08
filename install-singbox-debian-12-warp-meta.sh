cat > /root/install-singbox-warp.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail

clear

echo "============================================================"
echo " SING-BOX + NGINX + TLS + WARP - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " META/WA/FB/IG/MESSENGER/THREADS -> WARP"
echo " browserleaks.com -> WARP"
echo " SEMUA GEOSITE -> SRS"
echo " SSH / VPS DEFAULT ROUTE -> DIRECT"
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


# ============================================================
# VARIABLE
# ============================================================

UUID="9a5778c3-3db3-4107-b594-f3f2b9a4f0fc"

TROJAN_PASS="kuota_15_dec"

TROJAN_PORT="10001"
VMESS_PORT="10002"
VLESS_PORT="10003"

WARP_PORT="40000"

GO_VERSION="1.27.1"

GEOSITE_URL="https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

GEOSITE_FALLBACK="https://raw.githubusercontent.com/malikshi/v2ray-rules-dat/release/geosite.dat"

GEOSITE_DAT="/etc/sing-box/geosite.dat"

SRS_DIR="/etc/sing-box/rule-set"

export DEBIAN_FRONTEND=noninteractive


# ============================================================
# BACKUP
# ============================================================

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"

mkdir -p "$BACKUP"

cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true

cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true

cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true


# ============================================================
# 1. TIMEZONE
# ============================================================

echo
echo "============================================================"
echo " 1. TIMEZONE"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta


# ============================================================
# 2. PACKAGE
# ============================================================

echo
echo "============================================================"
echo " 2. INSTALL PACKAGE"
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
gpg \
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
git \
build-essential \
protobuf-compiler \
tar


# ============================================================
# NODEJS
# ============================================================

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

npm install -g pm2


# ============================================================
# 3. INSTALL GO RESMI
# ============================================================

echo
echo "============================================================"
echo " 3. INSTALL GO ${GO_VERSION}"
echo "============================================================"

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in

    amd64)
        GOARCH="amd64"
        ;;

    arm64)
        GOARCH="arm64"
        ;;

    *)
        echo "ERROR: Architecture tidak didukung: $ARCH"
        exit 1
        ;;

esac


rm -rf /usr/local/go

rm -f /tmp/go.tar.gz


wget \
--timeout=30 \
--tries=3 \
-O /tmp/go.tar.gz \
"https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"


tar -C /usr/local -xzf /tmp/go.tar.gz


ln -sf /usr/local/go/bin/go /usr/local/bin/go

ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt


export PATH="/usr/local/go/bin:$PATH"


echo
echo "===== GO VERSION ====="

go version


GO_MAJOR="$(go version | grep -oE 'go1\.[0-9]+' | cut -d. -f2)"


if [ "${GO_MAJOR:-0}" -lt 22 ]; then

    echo "ERROR: Go terlalu lama."

    exit 1

fi


# ============================================================
# 4. INSTALL SING-BOX
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
echo "===== SING-BOX VERSION ====="

sing-box version


# ============================================================
# 5. INSTALL CLOUDFLARE WARP
# ============================================================

echo
echo "============================================================"
echo " 5. INSTALL CLOUDFLARE WARP"
echo "============================================================"


install -d -m 0755 /usr/share/keyrings


curl -fsSL \
https://pkg.cloudflareclient.com/pubkey.gpg \
| gpg --yes --dearmor \
-o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg


cat > /etc/apt/sources.list.d/cloudflare-client.list <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main
EOF


apt-get update

apt-get install -y cloudflare-warp


systemctl enable warp-svc

systemctl restart warp-svc


sleep 3


echo
echo "===== REGISTRASI WARP ====="


warp-cli --accept-tos disconnect >/dev/null 2>&1 || true


if warp-cli --accept-tos registration show >/dev/null 2>&1; then

    echo "WARP sudah terdaftar."

else

    warp-cli --accept-tos registration new

fi


echo
echo "===== SET LOCAL PROXY MODE ====="


warp-cli --accept-tos mode proxy


warp-cli --accept-tos proxy port "$WARP_PORT"


# Proxy Mode versi WARP baru menggunakan MASQUE.
warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 || true


warp-cli --accept-tos connect


sleep 5


echo
echo "===== WARP STATUS ====="

warp-cli --accept-tos status || true


echo
echo "===== WARP SETTINGS ====="

warp-cli --accept-tos settings || true


echo
echo "===== TEST WARP SOCKS5 ====="


WARP_TEST="$(curl \
-4 \
--socks5-hostname "127.0.0.1:${WARP_PORT}" \
--connect-timeout 15 \
-fsS \
https://www.cloudflare.com/cdn-cgi/trace \
2>/dev/null || true)"


echo "$WARP_TEST" | grep -E '^(ip|warp)=' || true


if ! echo "$WARP_TEST" | grep -qE '^warp=(on|plus)$'; then

    echo
    echo "ERROR: WARP local proxy belum aktif."
    echo
    echo "Status:"
    warp-cli --accept-tos status || true
    echo
    echo "Port:"
    ss -lntup | grep ":${WARP_PORT}" || true
    exit 1

fi


echo
echo "WARP SOCKS5 BERHASIL."


# ============================================================
# 6. IPV6 OFF
# ============================================================

echo
echo "============================================================"
echo " 6. IPV4 ONLY"
echo "============================================================"


cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF


# ============================================================
# DNS
# ============================================================

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
# 7. BBR + HIGH CONNECTION
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
# 8. DOWNLOAD GEOSITE.DAT
# ============================================================

echo
echo "============================================================"
echo " 8. DOWNLOAD GEOSITE.DAT"
echo "============================================================"


mkdir -p /etc/sing-box

mkdir -p "$SRS_DIR"

mkdir -p /var/lib/sing-box

mkdir -p /var/log/sing-box


rm -f "$GEOSITE_DAT"


echo
echo "Download:"
echo "$GEOSITE_URL"
echo


if wget \
--timeout=30 \
--tries=3 \
-O "$GEOSITE_DAT" \
"$GEOSITE_URL"; then

    echo
    echo "Geosite berhasil."

else

    echo
    echo "URL release gagal."
    echo "Mencoba fallback..."

    wget \
    --timeout=30 \
    --tries=3 \
    -O "$GEOSITE_DAT" \
    "$GEOSITE_FALLBACK"

fi


if [ ! -s "$GEOSITE_DAT" ]; then

    echo "ERROR: geosite.dat kosong."

    exit 1

fi


echo
echo "===== GEOSITE.DAT ====="

ls -lh "$GEOSITE_DAT"


# ============================================================
# 9. BUILD GEODAT2SRS
# ============================================================

echo
echo "============================================================"
echo " 9. BUILD TOOL GEODAT -> SRS"
echo "============================================================"


export PATH="/usr/local/go/bin:$PATH"


echo
echo "Go yang digunakan:"
which go
go version


rm -rf /tmp/geodat2srs


git clone \
--depth=1 \
https://github.com/runetfreedom/geodat2srs.git \
/tmp/geodat2srs


cd /tmp/geodat2srs


echo
echo "===== GO.MOD ====="

cat go.mod


echo
echo "===== DOWNLOAD DEPENDENCY ====="


GOTOOLCHAIN=auto \
go mod download


echo
echo "===== BUILD ====="


GOTOOLCHAIN=auto \
go build \
-trimpath \
-o /usr/local/bin/geodat2srs \
.


chmod 755 /usr/local/bin/geodat2srs


echo
echo "===== TEST TOOL ====="

/usr/local/bin/geodat2srs --help


# ============================================================
# 10. CONVERT SEMUA GEOSITE -> SRS
# ============================================================

echo
echo "============================================================"
echo " 10. CONVERT SEMUA KATEGORI GEOSITE -> SRS"
echo "============================================================"


rm -rf "$SRS_DIR"

mkdir -p "$SRS_DIR"


/usr/local/bin/geodat2srs \
geosite \
-i "$GEOSITE_DAT" \
-o "$SRS_DIR"


SRS_COUNT="$(
    find "$SRS_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    | wc -l
)"


echo
echo "============================================================"
echo " TOTAL FILE SRS : $SRS_COUNT"
echo "============================================================"


if [ "$SRS_COUNT" -lt 1 ]; then

    echo "ERROR: Tidak ada file .srs."

    exit 1

fi


echo
echo "===== CONTOH SRS ====="


find "$SRS_DIR" \
-maxdepth 1 \
-type f \
-name '*.srs' \
| sort \
| head -50


# ============================================================
# 11. CARI CATEGORY META
# ============================================================

echo
echo "============================================================"
echo " 11. DETEKSI CATEGORY META"
echo "============================================================"


find_rule() {

    local SEARCH="$1"

    find "$SRS_DIR" \
    -maxdepth 1 \
    -type f \
    -iname "*${SEARCH}*.srs" \
    | sort \
    | head -1

}


META_SRS="$(find_rule meta || true)"

WHATSAPP_SRS="$(find_rule whatsapp || true)"

FACEBOOK_SRS="$(find_rule facebook || true)"

INSTAGRAM_SRS="$(find_rule instagram || true)"

MESSENGER_SRS="$(find_rule messenger || true)"

THREADS_SRS="$(find_rule threads || true)"


echo
echo "META      : ${META_SRS:-TIDAK ADA}"
echo "WHATSAPP  : ${WHATSAPP_SRS:-TIDAK ADA}"
echo "FACEBOOK  : ${FACEBOOK_SRS:-TIDAK ADA}"
echo "INSTAGRAM : ${INSTAGRAM_SRS:-TIDAK ADA}"
echo "MESSENGER : ${MESSENGER_SRS:-TIDAK ADA}"
echo "THREADS   : ${THREADS_SRS:-TIDAK ADA}"


# ============================================================
# 12. BUILD RULE-SET ARRAY
# ============================================================

echo
echo "============================================================"
echo " 12. BUILD RULE-SET"
echo "============================================================"


RULESET_JSON='[]'

RULE_TAGS='[]'


add_rule_set() {

    local TAG="$1"

    local FILE="$2"


    if [ -n "$FILE" ] && [ -f "$FILE" ]; then


        RULESET_JSON="$(
            jq \
            --arg tag "$TAG" \
            --arg path "$FILE" \
            '. + [{
                "type":"local",
                "tag":$tag,
                "format":"binary",
                "path":$path
            }]' \
            <<<"$RULESET_JSON"
        )"


        RULE_TAGS="$(
            jq \
            --arg tag "$TAG" \
            '. + [$tag]' \
            <<<"$RULE_TAGS"
        )"

    fi

}


add_rule_set \
"geosite-meta" \
"${META_SRS:-}"


add_rule_set \
"geosite-whatsapp" \
"${WHATSAPP_SRS:-}"


add_rule_set \
"geosite-facebook" \
"${FACEBOOK_SRS:-}"


add_rule_set \
"geosite-instagram" \
"${INSTAGRAM_SRS:-}"


add_rule_set \
"geosite-messenger" \
"${MESSENGER_SRS:-}"


add_rule_set \
"geosite-threads" \
"${THREADS_SRS:-}"


echo
echo "===== RULE TAGS ====="

echo "$RULE_TAGS" | jq .


# ============================================================
# 13. USER SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 13. CONFIG SING-BOX"
echo "============================================================"


if ! id sing-box >/dev/null 2>&1; then

    useradd \
    --system \
    --home /var/lib/sing-box \
    --shell /usr/sbin/nologin \
    sing-box

fi


touch /var/log/sing-box/sing-box.log


chown -R sing-box:sing-box \
/var/lib/sing-box \
/var/log/sing-box \
/etc/sing-box


chmod 755 /var/log/sing-box

chmod 664 /var/log/sing-box/sing-box.log


# ============================================================
# BASE CONFIG
# ============================================================

cat > /tmp/singbox-base.json <<EOF

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

            "server_port": ${WARP_PORT},

            "version": "5"
        }

    ],

    "route": {

        "rule_set": [],

        "rules": [],

        "final": "direct"

    }

}

EOF


# ============================================================
# FINAL CONFIG
# ============================================================

jq \
--argjson sets "$RULESET_JSON" \
--argjson tags "$RULE_TAGS" \
'

.route.rule_set = $sets |

.route.rules = (

    [

        {
            "ip_version": 6,
            "action": "reject"
        },


        {
            "domain": [
                "browserleaks.com"
            ],

            "domain_suffix": [
                "browserleaks.com"
            ],

            "action": "route",

            "outbound": "warp"
        },


        {
            "domain_suffix": [

                "facebook.com",

                "facebook.net",

                "fb.com",

                "fbcdn.net",

                "fbsbx.com",

                "fb.me",

                "facebookmail.com",

                "facebook-hardware.com",


                "instagram.com",

                "cdninstagram.com",

                "ig.me",


                "whatsapp.com",

                "whatsapp.net",

                "wa.me",


                "messenger.com",

                "m.me",


                "threads.net",

                "threads.com"

            ],

            "action": "route",

            "outbound": "warp"
        }

    ]


    +


    (
        if ($tags | length) > 0 then

            [

                {
                    "rule_set": $tags,

                    "action": "route",

                    "outbound": "warp"
                }

            ]

        else

            []

        end
    )


    +


    [

        {
            "action": "resolve",

            "strategy": "ipv4_only"
        }

    ]

)

' \
/tmp/singbox-base.json \
> /etc/sing-box/config.json


chown sing-box:sing-box \
/etc/sing-box/config.json


chmod 640 \
/etc/sing-box/config.json


# ============================================================
# CHECK CONFIG
# ============================================================

echo
echo "===== SING-BOX CHECK ====="


/usr/bin/sing-box check \
-c /etc/sing-box/config.json


# ============================================================
# 14. SYSTEMD SING-BOX
# ============================================================

echo
echo "============================================================"
echo " 14. SYSTEMD SING-BOX"
echo "============================================================"


systemctl stop sing-box \
2>/dev/null || true


cat > /etc/systemd/system/sing-box.service <<'EOF'

[Unit]

Description=sing-box Proxy Service

After=network-online.target warp-svc.service

Wants=network-online.target warp-svc.service


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

    echo
    echo "SING-BOX GAGAL START:"
    echo

    journalctl \
    -u sing-box \
    -n 100 \
    --no-pager

    exit 1

fi


# ============================================================
# 15. NGINX
# ============================================================

echo
echo "============================================================"
echo " 15. NGINX"
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


mkdir -p \
/etc/systemd/system/nginx.service.d


cat > /etc/systemd/system/nginx.service.d/override.conf <<'EOF'

[Service]

LimitNOFILE=1048576

LimitNPROC=1048576

TasksMax=1048576

EOF


systemctl daemon-reload


rm -f \
/etc/nginx/sites-enabled/default


mkdir -p \
/var/www/html/.well-known/acme-challenge


# ============================================================
# NGINX PORT 80
# ============================================================

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
# 16. CERTBOT
# ============================================================

echo
echo "============================================================"
echo " 16. TLS CERTIFICATE"
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


# ============================================================
# 17. NGINX TLS
# ============================================================

echo
echo "============================================================"
echo " 17. NGINX TLS + WEBSOCKET"
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

        proxy_pass \
        http://127.0.0.1:${TROJAN_PORT};


        proxy_http_version 1.1;


        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";


        proxy_set_header Host \$host;


        proxy_set_header X-Real-IP \$remote_addr;


        proxy_set_header X-Forwarded-For \
        \$proxy_add_x_forwarded_for;


        proxy_connect_timeout 10s;

        proxy_read_timeout 86400s;

        proxy_send_timeout 86400s;


        proxy_buffering off;

        proxy_request_buffering off;


        proxy_socket_keepalive on;

    }


    location /vmess {

        proxy_pass \
        http://127.0.0.1:${VMESS_PORT};


        proxy_http_version 1.1;


        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";


        proxy_set_header Host \$host;


        proxy_set_header X-Real-IP \$remote_addr;


        proxy_set_header X-Forwarded-For \
        \$proxy_add_x_forwarded_for;


        proxy_connect_timeout 10s;

        proxy_read_timeout 86400s;

        proxy_send_timeout 86400s;


        proxy_buffering off;

        proxy_request_buffering off;


        proxy_socket_keepalive on;

    }


    location /vless {

        proxy_pass \
        http://127.0.0.1:${VLESS_PORT};


        proxy_http_version 1.1;


        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";


        proxy_set_header Host \$host;


        proxy_set_header X-Real-IP \$remote_addr;


        proxy_set_header X-Forwarded-For \
        \$proxy_add_x_forwarded_for;


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


systemctl enable certbot.timer \
2>/dev/null || true


systemctl start certbot.timer \
2>/dev/null || true


# ============================================================
# 18. FIREWALL
# ============================================================

echo
echo "============================================================"
echo " 18. FIREWALL"
echo "============================================================"


ufw allow 22/tcp || true

ufw allow 80/tcp || true

ufw allow 443/tcp || true


# Jangan buka 40000 ke publik.
# WARP hanya listen localhost.


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


# ============================================================
# 20. FINAL RESTART
# ============================================================

echo
echo "============================================================"
echo " 20. FINAL RESTART"
echo "============================================================"


systemctl daemon-reload


systemctl restart warp-svc


sleep 3


warp-cli --accept-tos mode proxy \
>/dev/null 2>&1 || true


warp-cli --accept-tos proxy port "$WARP_PORT" \
>/dev/null 2>&1 || true


warp-cli --accept-tos tunnel protocol set MASQUE \
>/dev/null 2>&1 || true


warp-cli --accept-tos connect \
>/dev/null 2>&1 || true


sleep 5


systemctl restart sing-box

systemctl restart nginx


sleep 3


# ============================================================
# FINAL TEST
# ============================================================

clear


echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"

echo

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

echo "IPv4         : ONLY"

echo "IPv6         : OFF"

echo

echo "WARP Mode    : LOCAL PROXY"

echo "WARP SOCKS5  : 127.0.0.1:${WARP_PORT}"

echo

echo "SSH          : DIRECT"

echo "Default VPS  : DIRECT"

echo

echo "SRS Folder   : $SRS_DIR"

echo "Total SRS    : $SRS_COUNT"

echo

echo "WARP ROUTE:"

echo " - Meta"

echo " - WhatsApp"

echo " - Facebook"

echo " - Instagram"

echo " - Messenger"

echo " - Threads"

echo " - browserleaks.com"

echo

echo "============================================================"
echo " SERVICE"
echo "============================================================"


systemctl is-active \
warp-svc \
sing-box \
nginx \
|| true


echo
echo "============================================================"
echo " PORT"
echo "============================================================"


ss -lntup \
| grep -E \
":80 |:443 |:${TROJAN_PORT}|:${VMESS_PORT}|:${VLESS_PORT}|:${WARP_PORT}" \
|| true


echo
echo "============================================================"
echo " DEFAULT ROUTE VPS"
echo "============================================================"


ip -4 route show default


echo
echo "============================================================"
echo " WARP STATUS"
echo "============================================================"


warp-cli --accept-tos status || true


echo
echo "============================================================"
echo " IP VPS DIRECT"
echo "============================================================"


curl \
-4 \
--connect-timeout 10 \
-fsS \
https://www.cloudflare.com/cdn-cgi/trace \
| grep -E '^(ip|warp)=' \
|| true


echo
echo "============================================================"
echo " IP WARP"
echo "============================================================"


curl \
-4 \
--socks5-hostname "127.0.0.1:${WARP_PORT}" \
--connect-timeout 15 \
-fsS \
https://www.cloudflare.com/cdn-cgi/trace \
| grep -E '^(ip|warp)=' \
|| true


echo
echo "============================================================"
echo " GO VERSION"
echo "============================================================"


/usr/local/go/bin/go version


echo
echo "============================================================"
echo " GEODAT2SRS"
echo "============================================================"


command -v geodat2srs


echo
echo "============================================================"
echo " META SRS"
echo "============================================================"


echo "META      : ${META_SRS:-TIDAK ADA}"

echo "WHATSAPP  : ${WHATSAPP_SRS:-TIDAK ADA}"

echo "FACEBOOK  : ${FACEBOOK_SRS:-TIDAK ADA}"

echo "INSTAGRAM : ${INSTAGRAM_SRS:-TIDAK ADA}"

echo "MESSENGER : ${MESSENGER_SRS:-TIDAK ADA}"

echo "THREADS   : ${THREADS_SRS:-TIDAK ADA}"


echo
echo "============================================================"
echo " TEST SING-BOX"
echo "============================================================"


sing-box check \
-c /etc/sing-box/config.json


echo
echo "============================================================"
echo " TEST NGINX"
echo "============================================================"


nginx -t


echo
echo "============================================================"
echo " SELESAI"
echo "============================================================"

SCRIPT

chmod +x /root/install-singbox-warp.sh && /root/install-singbox-warp.sh
