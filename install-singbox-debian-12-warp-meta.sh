cat > /root/install-singbox-warp-full.sh <<'INSTALLER'
#!/bin/bash
set -Eeuo pipefail

clear
echo "============================================================"
echo " SING-BOX + NGINX + TLS - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " HIGH CONNECTION + IPV4 ONLY + BBR"
echo " GEOSITE -> SRS + CLOUDFLARE WARP"
echo " META / WHATSAPP / FACEBOOK / INSTAGRAM / MESSENGER / THREADS"
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
apt-get install -y curl wget unzip zip socat ca-certificates gnupg openssl nginx certbot ufw jq mtr-tiny dnsutils iproute2 net-tools procps python3

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
      "users":[{"password":"${TROJAN_PASS}"}],
      "transport":{"type":"ws","path":"/trojan"}
    },
    {
      "type":"vmess",
      "tag":"vmess-in",
      "listen":"127.0.0.1",
      "listen_port":${VMESS_PORT},
      "users":[{"uuid":"${UUID}","alterId":0}],
      "transport":{"type":"ws","path":"/vmess"}
    },
    {
      "type":"vless",
      "tag":"vless-in",
      "listen":"127.0.0.1",
      "listen_port":${VLESS_PORT},
      "users":[{"uuid":"${UUID}"}],
      "transport":{"type":"ws","path":"/vless"}
    }
  ],
  "outbounds": [
    {
      "type":"direct",
      "tag":"direct"
    }
  ],
  "route": {
    "rules":[
      {
        "ip_version":6,
        "action":"reject"
      },
      {
        "action":"resolve",
        "strategy":"ipv4_only"
      }
    ]
  }
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

ln -sf /etc/nginx/sites-available/singbox.conf /etc/nginx/sites-enabled/singbox.conf
nginx -t
systemctl enable nginx
systemctl restart nginx

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
echo "============================================================"
echo " BAGIAN 2 - CONVERT GEOSITE.DAT KE SRS"
echo "============================================================"

set +e

WORK="/root/geosite-convert"

mkdir -p "$WORK"
cd "$WORK" || {
    echo "Gagal masuk ke $WORK"
    exit 1
}

echo "============================================================"
echo "1. DOWNLOAD GEOSITE.DAT"
echo "============================================================"

wget -O geosite.dat \
"https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

if [ ! -s geosite.dat ]; then
    echo "ERROR: geosite.dat gagal didownload"
    exit 1
fi

ls -lh geosite.dat

echo
echo "============================================================"
echo "2. CEK V2DAT"
echo "============================================================"

if ! command -v v2dat >/dev/null 2>&1; then
    apt-get update
    apt-get install -y wget unzip

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            V2ARCH="amd64"
            ;;
        aarch64|arm64)
            V2ARCH="arm64"
            ;;
        *)
            echo "Arsitektur tidak didukung: $ARCH"
            exit 1
            ;;
    esac

    wget -O /tmp/v2dat.zip \
    "https://github.com/urlesistiana/v2dat/releases/latest/download/v2dat-linux-${V2ARCH}.zip"

    rm -rf /tmp/v2dat-install
    mkdir -p /tmp/v2dat-install

    unzip -o /tmp/v2dat.zip -d /tmp/v2dat-install

    BIN="$(find /tmp/v2dat-install -type f -name v2dat | head -1)"

    if [ -z "$BIN" ]; then
        echo "ERROR: v2dat tidak ditemukan"
        exit 1
    fi

    cp "$BIN" /usr/local/bin/v2dat
    chmod +x /usr/local/bin/v2dat
fi

v2dat --help

echo
echo "============================================================"
echo "3. EXTRACT SEMUA KATEGORI"
echo "============================================================"

rm -rf "$WORK/txt"
mkdir -p "$WORK/txt"

v2dat unpack geosite \
    -o "$WORK/txt" \
    "$WORK/geosite.dat"

echo
echo "Isi hasil extract:"
ls -lah "$WORK/txt" | head -30

TXT_COUNT="$(find "$WORK/txt" -type f -name '*.txt' | wc -l)"

echo
echo "JUMLAH KATEGORI = $TXT_COUNT"

echo
echo "============================================================"
echo "4. INSTALL / CEK SING-BOX"
echo "============================================================"

if ! command -v sing-box >/dev/null 2>&1; then
    curl -fsSL https://sing-box.app/deb-install.sh | bash
fi

sing-box version

echo
echo "============================================================"
echo "5. CONVERT SEMUA KATEGORI KE SRS"
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

    python3 - "$FILE" "$JSON" <<'PY'
import sys
import json

src = sys.argv[1]
dst = sys.argv[2]

domain = set()
domain_suffix = set()
domain_keyword = set()
domain_regex = set()

with open(src, "r", encoding="utf-8", errors="ignore") as f:
    for raw in f:
        line = raw.strip()

        if not line:
            continue

        if line.startswith("#"):
            continue

        if " @" in line:
            line = line.split(" @", 1)[0].strip()

        if not line:
            continue

        if line.startswith("full:"):
            x = line[5:].strip()
            if x:
                domain.add(x)

        elif line.startswith("domain:"):
            x = line[7:].strip()
            if x:
                domain_suffix.add(x)

        elif line.startswith("keyword:"):
            x = line[8:].strip()
            if x:
                domain_keyword.add(x)

        elif line.startswith("regexp:"):
            x = line[7:].strip()
            if x:
                domain_regex.add(x)

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
    "rules": [rule] if rule else []
}

with open(dst, "w", encoding="utf-8") as f:
    json.dump(
        result,
        f,
        ensure_ascii=False,
        separators=(",", ":")
    )
PY

    if sing-box rule-set compile "$JSON" -o "$SRS"; then
        echo "OK  : $NAME.srs"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "FAIL: $NAME"
        FAILED=$((FAILED + 1))
        rm -f "$SRS"
    fi

done < <(find "$WORK/txt" -type f -name '*.txt' -print0)

echo
echo "============================================================"
echo "6. HASIL"
echo "============================================================"

SRS_COUNT="$(find "$WORK/srs" -type f -name '*.srs' | wc -l)"

echo "Kategori TXT : $TXT_COUNT"
echo "SRS sukses   : $SUCCESS"
echo "SRS gagal    : $FAILED"
echo "File SRS     : $SRS_COUNT"

echo
echo "Lokasi:"
echo "$WORK/srs/"

echo
echo "============================================================"
echo "7. SEMUA NAMA KATEGORI"
echo "============================================================"

find "$WORK/srs" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '%f\n' \
    | sort

echo
echo "============================================================"
echo " BAGIAN 3 - INSTALL CLOUDFLARE WARP - SSH SAFE"
echo "============================================================"

apt-get update
apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    iproute2 \
    iptables \
    jq

SSH_CLIENT_IP="$(echo "${SSH_CLIENT:-}" | awk '{print $1}')"
SSH_SERVER_IP="$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')"

echo "SSH Client IP : ${SSH_CLIENT_IP:-unknown}"
echo "VPS IP        : ${SSH_SERVER_IP:-unknown}"

ip route show default

install -d -m 0755 /usr/share/keyrings

curl -fsSL \
https://pkg.cloudflareclient.com/pubkey.gpg \
| gpg --yes --dearmor \
-o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

echo "OS codename: $CODENAME"

cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main
EOF

apt-get update
apt-get install -y cloudflare-warp

systemctl enable warp-svc
systemctl restart warp-svc

sleep 2

systemctl --no-pager --full status warp-svc | head -20 || true

warp-cli disconnect >/dev/null 2>&1 || true
warp-cli registration delete >/dev/null 2>&1 || true
yes | warp-cli registration new

sleep 2

warp-cli registration show || true

# PROXY MODE = TIDAK MENGUBAH DEFAULT ROUTE VPS
warp-cli mode proxy

sleep 1

# SOCKS5 LOCAL WARP
warp-cli proxy port 40000

warp-cli connect

sleep 5

echo
echo "============================================================"
echo " STATUS WARP"
echo "============================================================"

warp-cli status || true

echo
echo "DEFAULT ROUTE VPS:"
ip route show default

echo
echo "IP ASLI VPS:"
curl -4 --max-time 10 https://api.ipify.org || true
echo

echo
echo "TRACE WARP:"
curl \
    --proxy socks5h://127.0.0.1:40000 \
    --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace || true

echo
echo "IP WARP:"
curl \
    --proxy socks5h://127.0.0.1:40000 \
    --max-time 20 \
    https://api.ipify.org || true

echo
echo "PORT WARP:"
ss -lntp | grep 40000 || true

echo
echo "============================================================"
echo " BAGIAN 4 - ROUTING META LEWAT WARP"
echo "============================================================"

# Beri akses sing-box membaca SRS.
chmod 755 /root
chmod 755 "$WORK"
chmod 755 "$WORK/srs"
find "$WORK/srs" -type f -name '*.srs' -exec chmod 644 {} \;

# Cari kategori yang benar-benar tersedia.
echo
echo "Kategori Meta yang ditemukan:"
find "$WORK/srs" -maxdepth 1 -type f \
  \( -iname '*meta*.srs' \
  -o -iname '*facebook*.srs' \
  -o -iname '*instagram*.srs' \
  -o -iname '*whatsapp*.srs' \
  -o -iname '*messenger*.srs' \
  -o -iname '*threads*.srs' \) \
  -printf '%f\n' | sort

python3 <<'PY'
import json
import os
import glob

CONFIG = "/etc/sing-box/config.json"
SRS_DIR = "/root/geosite-convert/srs"

with open(CONFIG, "r", encoding="utf-8") as f:
    cfg = json.load(f)

# ============================================================
# OUTBOUND WARP SOCKS5
# ============================================================

outbounds = cfg.setdefault("outbounds", [])

# Hapus warp lama jika script dijalankan ulang.
outbounds[:] = [
    x for x in outbounds
    if x.get("tag") != "warp"
]

outbounds.append({
    "type": "socks",
    "tag": "warp",
    "server": "127.0.0.1",
    "server_port": 40000
})

# ============================================================
# RULE-SET SRS
# ============================================================

wanted = (
    "meta",
    "facebook",
    "instagram",
    "whatsapp",
    "messenger",
    "threads"
)

files = sorted(glob.glob(os.path.join(SRS_DIR, "*.srs")))

selected = []

for path in files:
    name = os.path.basename(path).lower()

    if any(x in name for x in wanted):
        selected.append(path)

rule_sets = []
tags = []

for i, path in enumerate(selected):
    base = os.path.basename(path)
    tag = "warp-" + os.path.splitext(base)[0]

    rule_sets.append({
        "type": "local",
        "tag": tag,
        "format": "binary",
        "path": path
    })

    tags.append(tag)

route = cfg.setdefault("route", {})

# Pertahankan rule IPv6 + resolve asli.
old_rules = route.get("rules", [])

# Bersihkan routing warp lama jika ada.
clean_rules = []

for rule in old_rules:
    if rule.get("outbound") == "warp":
        continue

    if rule.get("action") == "route" and rule.get("outbound") == "warp":
        continue

    clean_rules.append(rule)

warp_rules = []

if tags:
    warp_rules.append({
        "rule_set": tags,
        "action": "route",
        "outbound": "warp"
    })

# Fallback domain eksplisit.
# Ini juga membantu Messenger/Threads yang biasanya berada
# di bawah infrastruktur Meta/Facebook/Instagram.
warp_rules.append({
    "domain_suffix": [
        "facebook.com",
        "facebook.net",
        "fb.com",
        "fbcdn.net",
        "fbsbx.com",
        "messenger.com",
        "m.me",
        "whatsapp.com",
        "whatsapp.net",
        "instagram.com",
        "cdninstagram.com",
        "threads.net",
        "threads.com",
        "meta.com",
        "metacareers.com",
        "browserleaks.com"
    ],
    "action": "route",
    "outbound": "warp"
})

# Routing WARP harus diperiksa sebelum rule resolve umum.
new_rules = []

for rule in clean_rules:
    if rule.get("action") == "resolve":
        continue
    new_rules.append(rule)

new_rules.extend(warp_rules)

for rule in clean_rules:
    if rule.get("action") == "resolve":
        new_rules.append(rule)

route["rules"] = new_rules

if rule_sets:
    route["rule_set"] = rule_sets
else:
    route.pop("rule_set", None)

with open(CONFIG, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)

print()
print("============================================================")
print("SRS DIPAKAI UNTUK WARP")
print("============================================================")

if selected:
    for path in selected:
        print(os.path.basename(path))
else:
    print("Tidak ditemukan kategori SRS Meta.")
    print("Routing domain fallback tetap aktif.")

print()
print("Total rule-set:", len(selected))
PY

echo
echo "============================================================"
echo " CEK CONFIG SETELAH ROUTING WARP"
echo "============================================================"

sing-box check -c /etc/sing-box/config.json

if [ $? -ne 0 ]; then
    echo
    echo "ERROR: CONFIG ROUTING WARP TIDAK VALID"
    echo "Config tidak akan direstart."
    exit 1
fi

systemctl restart sing-box
sleep 3

echo
echo "============================================================"
echo " CEK SERVICE"
echo "============================================================"

systemctl is-active sing-box nginx warp-svc || true

echo
echo "============================================================"
echo " CEK PORT"
echo "============================================================"

ss -lntp | grep -E ':80 |:443 |:10001|:10002|:10003|:40000' || true

echo
echo "============================================================"
echo " CEK BBR"
echo "============================================================"

sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control || true

echo
echo "============================================================"
echo " CEK IPV6"
echo "============================================================"

sysctl net.ipv6.conf.all.disable_ipv6 || true

echo
echo "============================================================"
echo " TEST CONFIG"
echo "============================================================"

sing-box check -c /etc/sing-box/config.json
nginx -t

echo
echo "============================================================"
echo " TEST WARP SOCKS5"
echo "============================================================"

curl \
  --proxy socks5h://127.0.0.1:40000 \
  --max-time 20 \
  https://www.cloudflare.com/cdn-cgi/trace || true

echo
echo "============================================================"
echo " TEST IP WARP"
echo "============================================================"

curl \
  --proxy socks5h://127.0.0.1:40000 \
  --max-time 20 \
  https://api.ipify.org || true

echo
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
echo "WARP SOCKS5 : 127.0.0.1:40000"
echo "SRS         : /root/geosite-convert/srs/"
echo
echo "ROUTING VIA WARP:"
echo "  - Meta"
echo "  - WhatsApp"
echo "  - Facebook"
echo "  - Instagram"
echo "  - Messenger"
echo "  - Threads"
echo "  - browserleaks.com"
echo
echo "TRAFFIC LAIN:"
echo "  - Direct / IP asli VPS"
echo
echo "SSH:"
echo "  - Tetap default route/IP asli VPS"
echo "============================================================"

echo
echo "STATUS:"
warp-cli status || true
systemctl --no-pager --full status sing-box | head -15 || true

echo
echo "DEFAULT ROUTE:"
ip route show default

echo
echo "IP ASLI VPS:"
curl -4 --max-time 10 https://api.ipify.org || true
echo

echo
echo "IP WARP:"
curl --proxy socks5h://127.0.0.1:40000 --max-time 20 https://api.ipify.org || true
echo

echo "============================================================"
echo " SELESAI"
echo "============================================================"
INSTALLER

chmod +x /root/install-singbox-warp-full.sh
/root/install-singbox-warp-full.sh
