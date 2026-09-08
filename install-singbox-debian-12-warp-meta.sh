cat > /root/install-singbox-warp-full.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail

clear
echo "============================================================"
echo " SING-BOX + NGINX + TLS - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " HIGH CONNECTION + IPV4 ONLY + BBR"
echo " WARP LOCAL PROXY + GEOSITE SRS"
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

WARP_PORT="40000"

GEOSITE_URL="https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"
GEOSITE_DIR="/root/geosite-convert"
RULE_DIR="/etc/sing-box/rule-set"

TARGETS=(
  meta
  whatsapp
  facebook
  instagram
  messenger
  threads
)

export DEBIAN_FRONTEND=noninteractive

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"
mkdir -p "$BACKUP"
cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true
cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true

timedatectl set-timezone Asia/Jakarta

echo
echo "===== PACKAGE ====="

apt-get update

apt-get install -y \
curl wget unzip zip socat ca-certificates gnupg openssl \
nginx certbot ufw jq mtr-tiny dnsutils iproute2 \
net-tools procps python3 git golang-go lsb-release

echo
echo "===== NODE.JS ====="

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
npm install -g pm2

echo
echo "===== SING-BOX ====="

mkdir -p /etc/apt/keyrings

curl -fsSL https://sing-box.app/gpg.key \
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
echo "===== BUILD V2DAT ====="

rm -rf /tmp/v2dat-source

git clone \
--depth 1 \
https://github.com/urlesistiana/v2dat.git \
/tmp/v2dat-source

cd /tmp/v2dat-source

go mod download

go build \
-trimpath \
-o /usr/local/bin/v2dat \
.

chmod +x /usr/local/bin/v2dat

echo
echo "===== TEST V2DAT ====="

v2dat --help

echo
echo "===== DOWNLOAD GEOSITE ====="

rm -rf "$GEOSITE_DIR"

mkdir -p \
"$GEOSITE_DIR/geosite" \
"$GEOSITE_DIR/json" \
"$GEOSITE_DIR/srs"

wget \
--tries=5 \
--timeout=30 \
-O "$GEOSITE_DIR/geosite.dat" \
"$GEOSITE_URL"

test -s "$GEOSITE_DIR/geosite.dat"

echo
echo "===== UNPACK GEOSITE ====="

v2dat unpack geosite \
-o "$GEOSITE_DIR/geosite" \
"$GEOSITE_DIR/geosite.dat"

echo
echo "TXT COUNT:"

find "$GEOSITE_DIR/geosite" \
-maxdepth 1 \
-type f \
-name '*.txt' \
| wc -l

echo
echo "===== CONVERT SEMUA KATEGORI KE SRS ====="

cat > "$GEOSITE_DIR/convert.py" <<'PY'
#!/usr/bin/env python3

import os
import glob
import json
import subprocess
import sys

SRC = "/root/geosite-convert/geosite"
JSON_DIR = "/root/geosite-convert/json"
SRS_DIR = "/root/geosite-convert/srs"

os.makedirs(JSON_DIR, exist_ok=True)
os.makedirs(SRS_DIR, exist_ok=True)

def add(rule, key, value):
    value = value.strip()
    if not value:
        return

    rule.setdefault(key, [])

    if value not in rule[key]:
        rule[key].append(value)

def get_name(path):
    name = os.path.basename(path)

    if name.endswith(".txt"):
        name = name[:-4]

    if name.startswith("geosite_"):
        name = name[8:]

    return name.lower()

files = sorted(glob.glob(os.path.join(SRC, "*.txt")))

if not files:
    print("ERROR: tidak ada TXT")
    sys.exit(1)

ok = 0
fail = 0

for path in files:

    name = get_name(path)

    rule = {}

    with open(path, "r", encoding="utf-8", errors="ignore") as f:

        for raw in f:

            line = raw.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            if line.startswith("full:"):

                add(rule, "domain", line[5:])

            elif line.startswith("domain:"):

                add(rule, "domain_suffix", line[7:])

            elif line.startswith("keyword:"):

                add(rule, "domain_keyword", line[8:])

            elif line.startswith("regexp:"):

                add(rule, "domain_regex", line[7:])

            elif line.startswith("include:"):

                continue

            elif line.startswith("@"):

                continue

            else:

                add(rule, "domain_suffix", line)

    obj = {
        "version": 3,
        "rules": []
    }

    if rule:
        obj["rules"].append(rule)

    json_path = os.path.join(
        JSON_DIR,
        name + ".json"
    )

    srs_path = os.path.join(
        SRS_DIR,
        name + ".srs"
    )

    with open(json_path, "w", encoding="utf-8") as f:

        json.dump(
            obj,
            f,
            ensure_ascii=False
        )

    try:

        subprocess.run(
            [
                "/usr/bin/sing-box",
                "rule-set",
                "compile",
                "--output",
                srs_path,
                json_path
            ],
            check=True
        )

        print("[OK]", name + ".srs")
        ok += 1

    except Exception as e:

        print("[FAIL]", name, e)
        fail += 1

print()
print("BERHASIL:", ok)
print("GAGAL   :", fail)

if ok == 0:
    sys.exit(1)
PY

chmod +x "$GEOSITE_DIR/convert.py"

python3 "$GEOSITE_DIR/convert.py"

echo
echo "===== TOTAL SRS ====="

find "$GEOSITE_DIR/srs" \
-maxdepth 1 \
-type f \
-name '*.srs' \
| wc -l

echo
echo "===== TARGET SRS ====="

AVAILABLE_RULES=()

for TAG in "${TARGETS[@]}"; do

    if [ -f "$GEOSITE_DIR/srs/${TAG}.srs" ]; then

        echo "[ADA] ${TAG}.srs"

        AVAILABLE_RULES+=("$TAG")

    else

        echo "[TIDAK ADA] ${TAG}.srs"

    fi

done

if [ "${#AVAILABLE_RULES[@]}" -eq 0 ]; then
    echo "ERROR: Tidak ada kategori target."
    exit 1
fi

echo
echo "===== INSTALL WARP ====="

mkdir -p /usr/share/keyrings

curl -fsSL \
https://pkg.cloudflareclient.com/pubkey.gpg \
| gpg --dearmor --yes \
-o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo \
"deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
> /etc/apt/sources.list.d/cloudflare-client.list

apt-get update
apt-get install -y cloudflare-warp

systemctl enable --now warp-svc

sleep 3

echo
echo "===== REGISTER WARP ====="

if ! warp-cli registration show >/dev/null 2>&1; then

    warp-cli \
    --accept-tos \
    registration new

fi

echo
echo "===== WARP LOCAL PROXY ====="

warp-cli \
--accept-tos \
disconnect \
>/dev/null 2>&1 || true

warp-cli \
--accept-tos \
tunnel protocol set MASQUE \
>/dev/null 2>&1 || true

warp-cli \
--accept-tos \
mode proxy

warp-cli \
--accept-tos \
proxy port "$WARP_PORT"

warp-cli \
--accept-tos \
connect

sleep 5

echo
echo "===== WARP STATUS ====="

warp-cli --accept-tos status || true

ss -lntp | grep ":${WARP_PORT}" || {
    echo "ERROR: WARP proxy tidak aktif."
    exit 1
}

echo
echo "===== TEST WARP ====="

curl \
--socks5-hostname 127.0.0.1:${WARP_PORT} \
--max-time 20 \
-s \
https://www.cloudflare.com/cdn-cgi/trace \
| grep -E '^(ip|colo|warp)=' \
|| true

echo
echo "===== IPV6 OFF ====="

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
echo "===== USER SING-BOX ====="

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
/var/log/sing-box \
"$RULE_DIR"

touch /var/log/sing-box/sing-box.log

chown -R \
sing-box:sing-box \
/var/lib/sing-box \
/var/log/sing-box

chmod 755 /var/log/sing-box

chmod 664 /var/log/sing-box/sing-box.log

echo
echo "===== COPY SRS TARGET ====="

for TAG in "${AVAILABLE_RULES[@]}"; do

    cp -f \
    "$GEOSITE_DIR/srs/${TAG}.srs" \
    "$RULE_DIR/${TAG}.srs"

done

echo
echo "===== BUILD RULE_SET ====="

RULE_SET_JSON=""

for TAG in "${AVAILABLE_RULES[@]}"; do

ITEM=$(cat <<EOF
{
  "type":"local",
  "tag":"${TAG}",
  "format":"binary",
  "path":"/etc/sing-box/rule-set/${TAG}.srs"
}
EOF
)

    if [ -z "$RULE_SET_JSON" ]; then

        RULE_SET_JSON="$ITEM"

    else

        RULE_SET_JSON="$RULE_SET_JSON,$ITEM"

    fi

done

RULE_LIST_JSON="$(printf '%s\n' "${AVAILABLE_RULES[@]}" | jq -R . | jq -s .)"

echo
echo "===== CONFIG SING-BOX ====="

cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level":"warn",
    "output":"/var/log/sing-box/sing-box.log",
    "timestamp":true
  },

  "inbounds": [
    {
      "type":"trojan",
      "tag":"trojan-in",
      "listen":"127.0.0.1",
      "listen_port":${TROJAN_PORT},
      "users":[
        {
          "password":"${TROJAN_PASS}"
        }
      ],
      "transport":{
        "type":"ws",
        "path":"/trojan"
      }
    },

    {
      "type":"vmess",
      "tag":"vmess-in",
      "listen":"127.0.0.1",
      "listen_port":${VMESS_PORT},
      "users":[
        {
          "uuid":"${UUID}",
          "alterId":0
        }
      ],
      "transport":{
        "type":"ws",
        "path":"/vmess"
      }
    },

    {
      "type":"vless",
      "tag":"vless-in",
      "listen":"127.0.0.1",
      "listen_port":${VLESS_PORT},
      "users":[
        {
          "uuid":"${UUID}"
        }
      ],
      "transport":{
        "type":"ws",
        "path":"/vless"
      }
    }
  ],

  "outbounds": [
    {
      "type":"direct",
      "tag":"direct"
    },

    {
      "type":"socks",
      "tag":"warp",
      "server":"127.0.0.1",
      "server_port":${WARP_PORT},
      "version":"5"
    }
  ],

  "route": {

    "rule_set":[
      ${RULE_SET_JSON}
    ],

    "rules":[

      {
        "rule_set":${RULE_LIST_JSON},
        "action":"route",
        "outbound":"warp"
      },

      {
        "domain_suffix":[
          "browserleaks.com"
        ],
        "action":"route",
        "outbound":"warp"
      },

      {
        "ip_version":6,
        "action":"reject"
      },

      {
        "action":"resolve",
        "strategy":"ipv4_only"
      }
    ],

    "final":"direct"
  }
}
EOF

echo
echo "===== PERMISSION ====="

chown root:sing-box \
/etc/sing-box/config.json

chmod 640 \
/etc/sing-box/config.json

chown -R root:sing-box \
"$RULE_DIR"

find "$RULE_DIR" \
-type d \
-exec chmod 750 {} \;

find "$RULE_DIR" \
-type f \
-exec chmod 640 {} \;

chmod 755 \
/etc/sing-box

echo
echo "===== CHECK CONFIG ====="

runuser \
-u sing-box \
-- /usr/bin/sing-box check \
-c /etc/sing-box/config.json

echo
echo "===== SYSTEMD SING-BOX ====="

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

echo
echo "===== NGINX ====="

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
echo "===== SSL ====="

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

echo
echo "===== FIREWALL ====="

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

echo
echo "===== LOGROTATE ====="

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
echo "===== START ====="

systemctl daemon-reload

systemctl restart warp-svc

sleep 2

warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port "$WARP_PORT" >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true

sleep 3

systemctl restart sing-box
systemctl restart nginx

sleep 4

echo
echo "===== STATUS ====="

systemctl is-active warp-svc sing-box nginx || true

echo
echo "===== WARP ====="

warp-cli --accept-tos status || true

ss -lntp | grep ":${WARP_PORT}" || true

echo
echo "===== WARP TEST ====="

curl \
--socks5-hostname 127.0.0.1:${WARP_PORT} \
--max-time 20 \
-s \
https://www.cloudflare.com/cdn-cgi/trace \
| grep -E '^(ip|colo|warp)=' \
|| true

echo
echo "===== DEFAULT ROUTE VPS ====="

ip -4 route show default

echo
echo "===== PORT ====="

ss -lntp \
| grep -E ':80 |:443 |:10001|:10002|:10003|:40000' \
|| true

echo
echo "===== BBR ====="

sysctl \
net.core.default_qdisc \
net.ipv4.tcp_congestion_control \
|| true

echo
echo "===== IPV6 ====="

sysctl net.ipv6.conf.all.disable_ipv6 || true

echo
echo "===== TEST CONFIG ====="

sing-box check -c /etc/sing-box/config.json
nginx -t

echo
echo "===== ROUTE WARP ====="

jq '
{
  warp_outbound:
    [.outbounds[] | select(.tag=="warp")],

  warp_rules:
    [.route.rules[] | select(.outbound=="warp")],

  rule_sets:
    .route.rule_set,

  final:
    .route.final
}
' /etc/sing-box/config.json

echo
echo "===== TARGET SRS ====="

ls -lh \
"$RULE_DIR"/*.srs \
2>/dev/null || true

echo
echo "===== SEMUA SRS ====="

find "$GEOSITE_DIR/srs" \
-maxdepth 1 \
-type f \
-name '*.srs' \
| wc -l

echo
echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"

echo "Domain      : $DOMAIN"
echo "Trojan Pass : $TROJAN_PASS"
echo "UUID        : $UUID"

echo "Trojan WS   : /trojan"
echo "VMess WS    : /vmess"
echo "VLESS WS    : /vless"

echo "Port TLS    : 443"

echo "IPv6        : OFF"
echo "IPv4        : ONLY"

echo
echo "WARP SOCKS  : 127.0.0.1:${WARP_PORT}"

echo
echo "ROUTE WARP:"

for TAG in "${AVAILABLE_RULES[@]}"; do
    echo " - ${TAG}.srs"
done

echo " - browserleaks.com"

echo
echo "TRAFIK LAIN : DIRECT VPS"
echo "SSH VPS     : DIRECT VPS"
echo "DEFAULT ROUTE VPS TIDAK DIUBAH WARP"

echo
echo "SEMUA SRS:"
echo "$GEOSITE_DIR/srs/"

echo "============================================================"

SCRIPT

chmod +x /root/install-singbox-warp-full.sh

/root/install-singbox-warp-full.sh
