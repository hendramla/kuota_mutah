cat > /root/install-singbox-warp.sh <<'SCRIPT'
#!/bin/bash
set -Eeuo pipefail

clear
echo "============================================================"
echo " SING-BOX + NGINX + TLS + WARP - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " META/WHATSAPP/FB/IG/MESSENGER/THREADS -> WARP"
echo " GEOSITE.DAT -> ALL SRS"
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
echo " INSTALL PACKAGE"
echo "============================================================"

apt-get update
apt-get install -y \
  curl wget unzip zip socat ca-certificates gnupg openssl \
  nginx certbot ufw jq mtr-tiny dnsutils iproute2 \
  net-tools procps git build-essential

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs
npm install -g pm2

echo
echo "============================================================"
echo " INSTALL SING-BOX"
echo "============================================================"

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

echo
echo "============================================================"
echo " INSTALL V2DAT"
echo "============================================================"

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
  amd64)
    V2DAT_ARCH="amd64"
    ;;
  arm64)
    V2DAT_ARCH="arm64"
    ;;
  *)
    echo "ERROR: Arsitektur v2dat belum didukung otomatis: $ARCH"
    exit 1
    ;;
esac

cd /tmp
rm -f /tmp/v2dat.zip

wget -O /tmp/v2dat.zip \
  "https://github.com/urlesistiana/v2dat/releases/latest/download/v2dat-linux-${V2DAT_ARCH}.zip"

rm -rf /tmp/v2dat-extract
mkdir -p /tmp/v2dat-extract
unzip -o /tmp/v2dat.zip -d /tmp/v2dat-extract

V2DAT_BIN="$(find /tmp/v2dat-extract -type f -name v2dat | head -1)"

if [ -z "$V2DAT_BIN" ]; then
  echo "ERROR: Binary v2dat tidak ditemukan."
  exit 1
fi

install -m 755 "$V2DAT_BIN" /usr/local/bin/v2dat

v2dat --help

echo
echo "============================================================"
echo " DOWNLOAD GEOSITE.DAT"
echo "============================================================"

mkdir -p /etc/sing-box/geosite
mkdir -p /etc/sing-box/rule-set
mkdir -p /tmp/geosite-unpack

wget -O /etc/sing-box/geosite.dat "$GEOSITE_URL"

if [ ! -s /etc/sing-box/geosite.dat ]; then
  echo "ERROR: geosite.dat gagal didownload."
  exit 1
fi

echo
echo "============================================================"
echo " UNPACK SEMUA KATEGORI GEOSITE"
echo "============================================================"

rm -rf /tmp/geosite-unpack/*
cd /tmp/geosite-unpack

v2dat unpack geosite \
  -f /etc/sing-box/geosite.dat \
  -o /tmp/geosite-unpack

echo
echo "File hasil unpack:"
find /tmp/geosite-unpack -type f | head -30 || true

echo
echo "============================================================"
echo " CONVERT SEMUA KATEGORI KE SRS"
echo "============================================================"

python3 <<'PY'
import os
import re
import json
import subprocess

src_root = "/tmp/geosite-unpack"
json_root = "/etc/sing-box/rule-set-json"
srs_root = "/etc/sing-box/rule-set"

os.makedirs(json_root, exist_ok=True)
os.makedirs(srs_root, exist_ok=True)

def clean_name(name):
    name = os.path.basename(name)
    name = os.path.splitext(name)[0]
    if name.startswith("geosite_"):
        name = name[len("geosite_"):]
    name = re.sub(r"[^a-zA-Z0-9_.@+-]+", "-", name)
    return name.lower()

def parse_file(path):
    domain = []
    domain_suffix = []
    domain_keyword = []
    domain_regex = []

    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()

            if not line:
                continue

            if line.startswith("#"):
                continue

            attr = ""
            if " @" in line:
                line, attr = line.split(" @", 1)
                line = line.strip()

            if line.startswith("full:"):
                value = line[5:].strip()
                if value:
                    domain.append(value)

            elif line.startswith("domain:"):
                value = line[7:].strip()
                if value:
                    domain_suffix.append(value)

            elif line.startswith("keyword:"):
                value = line[8:].strip()
                if value:
                    domain_keyword.append(value)

            elif line.startswith("regexp:"):
                value = line[7:].strip()
                if value:
                    domain_regex.append(value)

            elif line.startswith("regex:"):
                value = line[6:].strip()
                if value:
                    domain_regex.append(value)

            else:
                value = line.strip()
                if value:
                    domain_suffix.append(value)

    rule = {}

    if domain:
        rule["domain"] = sorted(set(domain))

    if domain_suffix:
        rule["domain_suffix"] = sorted(set(domain_suffix))

    if domain_keyword:
        rule["domain_keyword"] = sorted(set(domain_keyword))

    if domain_regex:
        rule["domain_regex"] = sorted(set(domain_regex))

    return rule

converted = []
failed = []

for root, dirs, files in os.walk(src_root):
    for filename in files:
        path = os.path.join(root, filename)

        if not os.path.isfile(path):
            continue

        name = clean_name(filename)

        try:
            rule = parse_file(path)

            if not rule:
                continue

            out_json = os.path.join(json_root, f"{name}.json")
            out_srs = os.path.join(srs_root, f"{name}.srs")

            data = {
                "version": 3,
                "rules": [
                    rule
                ]
            }

            with open(out_json, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, separators=(",", ":"))

            result = subprocess.run(
                [
                    "/usr/bin/sing-box",
                    "rule-set",
                    "compile",
                    "--output",
                    out_srs,
                    out_json
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )

            if result.returncode == 0:
                converted.append(name)
            else:
                failed.append((name, result.stderr.strip()))

        except Exception as e:
            failed.append((name, str(e)))

print("")
print("==============================================")
print("HASIL CONVERT GEOSITE -> SRS")
print("==============================================")
print("Sukses :", len(converted))
print("Gagal  :", len(failed))

if converted:
    print("")
    print("Contoh kategori:")
    for x in sorted(converted)[:50]:
        print(" -", x)

if failed:
    print("")
    print("Beberapa kategori gagal:")
    for name, err in failed[:20]:
        print(" -", name, ":", err[:200])
PY

SRS_COUNT="$(find /etc/sing-box/rule-set -type f -name '*.srs' | wc -l)"

echo
echo "Total SRS : $SRS_COUNT"

if [ "$SRS_COUNT" -eq 0 ]; then
  echo "ERROR: Tidak ada file SRS yang berhasil dibuat."
  exit 1
fi

echo
echo "============================================================"
echo " BUAT RULESET META FALLBACK"
echo "============================================================"

cat > /etc/sing-box/meta-fallback.json <<'EOF'
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
        "fb.me",
        "messenger.com",
        "m.me",

        "instagram.com",
        "cdninstagram.com",

        "whatsapp.com",
        "whatsapp.net",

        "threads.net",

        "meta.com",
        "meta.ai",
        "metacareers.com",
        "metacdn.com",
        "metamask.io",

        "browserleaks.com"
      ]
    }
  ]
}
EOF

sing-box rule-set compile \
  --output /etc/sing-box/rule-set/meta-fallback.srs \
  /etc/sing-box/meta-fallback.json

echo
echo "============================================================"
echo " CARI KATEGORI META DI GEOSITE"
echo "============================================================"

find /etc/sing-box/rule-set -maxdepth 1 -type f -name '*.srs' \
  | sed 's#.*/##;s#\.srs$##' \
  | grep -Ei '(^|[-_])(meta|facebook|instagram|whatsapp|messenger|threads)([-_@]|$)' \
  | sort -u \
  > /tmp/meta-srs-categories.txt || true

cat /tmp/meta-srs-categories.txt || true

echo
echo "============================================================"
echo " INSTALL WARP WIREGUARD OUTBOUND"
echo "============================================================"

mkdir -p /etc/sing-box/warp

# WARP account registration memakai wgcf.
# wgcf hanya membuat profil WireGuard.
# TIDAK menjalankan warp-cli connect dan TIDAK mengganti default route VPS.

WGCF_ARCH="$ARCH"

case "$WGCF_ARCH" in
  amd64)
    WGCF_SUFFIX="linux_amd64"
    ;;
  arm64)
    WGCF_SUFFIX="linux_arm64"
    ;;
  *)
    echo "ERROR: Arsitektur wgcf tidak didukung: $WGCF_ARCH"
    exit 1
    ;;
esac

WGCF_URL="$(
  curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
  | jq -r --arg suffix "$WGCF_SUFFIX" \
    '.assets[] | select(.name | contains($suffix)) | .browser_download_url' \
  | head -1
)"

if [ -z "$WGCF_URL" ] || [ "$WGCF_URL" = "null" ]; then
  echo "ERROR: URL wgcf tidak ditemukan."
  exit 1
fi

wget -O /usr/local/bin/wgcf "$WGCF_URL"
chmod +x /usr/local/bin/wgcf

cd /etc/sing-box/warp

rm -f wgcf-account.toml wgcf-profile.conf

yes | wgcf register

wgcf generate

if [ ! -f /etc/sing-box/warp/wgcf-profile.conf ]; then
  echo "ERROR: Profil WARP gagal dibuat."
  exit 1
fi

WARP_PRIVATE_KEY="$(
  awk -F' *= *' '/^PrivateKey/{print $2}' \
  /etc/sing-box/warp/wgcf-profile.conf \
  | tr -d ' '
)"

WARP_PUBLIC_KEY="$(
  awk -F' *= *' '/^PublicKey/{print $2}' \
  /etc/sing-box/warp/wgcf-profile.conf \
  | tr -d ' '
)"

WARP_ENDPOINT="$(
  awk -F' *= *' '/^Endpoint/{print $2}' \
  /etc/sing-box/warp/wgcf-profile.conf \
  | tr -d ' '
)"

WARP_RESERVED="$(
  awk -F' *= *' '/^Reserved/{print $2}' \
  /etc/sing-box/warp/wgcf-profile.conf \
  | tr -d ' ' || true
)"

WARP_ENDPOINT_HOST="${WARP_ENDPOINT%:*}"
WARP_ENDPOINT_PORT="${WARP_ENDPOINT##*:}"

if [ -z "$WARP_PRIVATE_KEY" ]; then
  echo "ERROR: PrivateKey WARP kosong."
  exit 1
fi

if [ -z "$WARP_PUBLIC_KEY" ]; then
  echo "ERROR: PublicKey WARP kosong."
  exit 1
fi

if [ -z "$WARP_ENDPOINT_HOST" ]; then
  WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
fi

if [ -z "$WARP_ENDPOINT_PORT" ] || ! [[ "$WARP_ENDPOINT_PORT" =~ ^[0-9]+$ ]]; then
  WARP_ENDPOINT_PORT="2408"
fi

echo "WARP endpoint : ${WARP_ENDPOINT_HOST}:${WARP_ENDPOINT_PORT}"

echo
echo "============================================================"
echo " DISABLE IPV6 VPS"
echo "============================================================"

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

echo
echo "============================================================"
echo " NETWORK TUNING"
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

echo
echo "============================================================"
echo " PREPARE SING-BOX"
echo "============================================================"

if ! id sing-box >/dev/null 2>&1; then
  useradd --system \
    --home /var/lib/sing-box \
    --shell /usr/sbin/nologin \
    sing-box
fi

mkdir -p /etc/sing-box /var/lib/sing-box /var/log/sing-box

touch /var/log/sing-box/sing-box.log

chown -R sing-box:sing-box \
  /var/lib/sing-box \
  /var/log/sing-box \
  /etc/sing-box/rule-set

chmod 755 /var/log/sing-box
chmod 664 /var/log/sing-box/sing-box.log
chmod 644 /etc/sing-box/rule-set/*.srs

echo
echo "============================================================"
echo " GENERATE SING-BOX CONFIG"
echo "============================================================"

python3 <<PY
import json
import os
import re

domain = ${DOMAIN@Q}
uuid = ${UUID@Q}
trojan_pass = ${TROJAN_PASS@Q}
trojan_port = int(${TROJAN_PORT})
vmess_port = int(${VMESS_PORT})
vless_port = int(${VLESS_PORT})

warp_private_key = ${WARP_PRIVATE_KEY@Q}
warp_public_key = ${WARP_PUBLIC_KEY@Q}
warp_endpoint_host = ${WARP_ENDPOINT_HOST@Q}
warp_endpoint_port = int(${WARP_ENDPOINT_PORT})

rule_dir = "/etc/sing-box/rule-set"

all_rule_files = sorted(
    x for x in os.listdir(rule_dir)
    if x.endswith(".srs")
)

rule_sets = []

for filename in all_rule_files:
    tag = filename[:-4]

    rule_sets.append({
        "type": "local",
        "tag": tag,
        "format": "binary",
        "path": os.path.join(rule_dir, filename)
    })

meta_candidates = []

patterns = [
    r"(^|[-_])meta([-_@]|$)",
    r"(^|[-_])facebook([-_@]|$)",
    r"(^|[-_])instagram([-_@]|$)",
    r"(^|[-_])whatsapp([-_@]|$)",
    r"(^|[-_])messenger([-_@]|$)",
    r"(^|[-_])threads([-_@]|$)"
]

for filename in all_rule_files:
    tag = filename[:-4]

    if tag == "meta-fallback":
        continue

    if any(re.search(p, tag, flags=re.I) for p in patterns):
        meta_candidates.append(tag)

warp_rulesets = ["meta-fallback"] + sorted(set(meta_candidates))

config = {
    "log": {
        "level": "warn",
        "output": "/var/log/sing-box/sing-box.log",
        "timestamp": True
    },

    "dns": {
        "servers": [
            {
                "type": "https",
                "tag": "cloudflare-dns",
                "server": "1.1.1.1",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "direct"
            }
        ],
        "final": "cloudflare-dns",
        "strategy": "ipv4_only"
    },

    "inbounds": [
        {
            "type": "trojan",
            "tag": "trojan-in",
            "listen": "127.0.0.1",
            "listen_port": trojan_port,
            "users": [
                {
                    "password": trojan_pass
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
            "listen_port": vmess_port,
            "users": [
                {
                    "uuid": uuid,
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
            "listen_port": vless_port,
            "users": [
                {
                    "uuid": uuid
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
            "type": "wireguard",
            "tag": "warp",
            "server": warp_endpoint_host,
            "server_port": warp_endpoint_port,
            "local_address": [
                "172.16.0.2/32",
                "2606:4700:110:8f77:1ee8:a96d:d6c8:f9a6/128"
            ],
            "private_key": warp_private_key,
            "peer_public_key": warp_public_key,
            "mtu": 1280
        }
    ],

    "route": {
        "rule_set": rule_sets,

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
                "rule_set": warp_rulesets,
                "action": "route",
                "outbound": "warp"
            }
        ],

        "final": "direct",
        "auto_detect_interface": True
    }
}

with open("/etc/sing-box/config.json", "w") as f:
    json.dump(config, f, indent=2)

print("")
print("Rule-set Meta yang diarahkan ke WARP:")
for x in warp_rulesets:
    print(" -", x)

print("")
print("Jumlah seluruh kategori SRS:", len(rule_sets))
PY

/usr/bin/sing-box check -c /etc/sing-box/config.json

echo
echo "============================================================"
echo " SYSTEMD SING-BOX"
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

AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

sleep 3

if ! systemctl is-active --quiet sing-box; then
  echo "ERROR: sing-box gagal start."
  journalctl -u sing-box -n 150 --no-pager
  exit 1
fi

echo
echo "============================================================"
echo " NGINX"
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
echo " TLS CERTIFICATE"
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
echo "============================================================"
echo " FIREWALL"
echo "============================================================"

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

sleep 5

echo
echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"
echo "Domain      : $DOMAIN"
echo "Trojan Pass : $TROJAN_PASS"
echo "UUID        : $UUID"
echo
echo "Trojan WS   : /trojan"
echo "VMess WS    : /vmess"
echo "VLESS WS    : /vless"
echo "Port TLS    : 443"
echo
echo "IPv6 VPS    : OFF"
echo "IPv4        : ONLY"
echo
echo "WARP        : SELECTIVE OUTBOUND"
echo "SSH Route   : TIDAK DIUBAH"
echo
echo "Meta        : WARP"
echo "WhatsApp    : WARP"
echo "Facebook    : WARP"
echo "Instagram   : WARP"
echo "Messenger   : WARP"
echo "Threads     : WARP"
echo "browserleaks.com : WARP"
echo
echo "SRS total   : $(find /etc/sing-box/rule-set -name '*.srs' | wc -l)"
echo "============================================================"

echo
echo "===== STATUS ====="
systemctl is-active sing-box nginx || true

echo
echo "===== PORT ====="
ss -lntp | grep -E ':80 |:443 |:10001|:10002|:10003' || true

echo
echo "===== BBR ====="
sysctl net.core.default_qdisc \
       net.ipv4.tcp_congestion_control || true

echo
echo "===== IPV6 ====="
sysctl net.ipv6.conf.all.disable_ipv6 || true

echo
echo "===== WARP PROFILE ====="
grep -E '^(Address|Endpoint|PublicKey)' \
  /etc/sing-box/warp/wgcf-profile.conf || true

echo
echo "===== META SRS ====="
cat /tmp/meta-srs-categories.txt 2>/dev/null || true

echo
echo "===== JUMLAH SRS ====="
find /etc/sing-box/rule-set -type f -name '*.srs' | wc -l

echo
echo "===== TEST CONFIG ====="
sing-box check -c /etc/sing-box/config.json
nginx -t

echo
echo "===== TEST DIRECT IP VPS ====="
curl -4 -s --max-time 15 https://api.ipify.org || true
echo

echo
echo "============================================================"
echo "CATATAN PENTING"
echo "============================================================"
echo "WARP tidak dijadikan default route OS."
echo "SSH tetap keluar melalui koneksi VPS asli."
echo "Hanya trafik yang cocok rule Meta/browserleaks yang keluar WARP."
echo "============================================================"
SCRIPT

chmod +x /root/install-singbox-warp.sh
/root/install-singbox-warp.sh
