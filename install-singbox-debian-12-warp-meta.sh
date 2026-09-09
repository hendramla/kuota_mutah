cat > /root/install-singbox-warp.sh <<'INSTALLER'
#!/bin/bash
set -Eeuo pipefail

clear

echo "============================================================"
echo " SING-BOX + NGINX + TLS + WARP - DEBIAN 12"
echo " TROJAN + VMESS + VLESS - WEBSOCKET TLS"
echo " GEOSITE -> SRS + META SOCIAL VIA WARP"
echo " SSH SAFE + IPV4 ONLY + BBR"
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

WORK="/root/geosite-convert"
RULE_DIR="/etc/sing-box/rule-set"

GEOSITE_URL="https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

export DEBIAN_FRONTEND=noninteractive

echo
echo "============================================================"
echo " DOMAIN"
echo "============================================================"
echo "Domain      : $DOMAIN"
echo "UUID        : $UUID"
echo "Trojan Pass : $TROJAN_PASS"

echo
echo "============================================================"
echo "1. TIMEZONE"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta

echo
echo "============================================================"
echo "2. INSTALL PACKAGE"
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
    iptables \
    net-tools \
    procps \
    python3 \
    lsb-release \
    git \
    golang-go

echo
echo "============================================================"
echo "3. NODEJS 24 + PM2"
echo "============================================================"

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

npm install -g pm2

echo
echo "============================================================"
echo "4. INSTALL SING-BOX"
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

sing-box version

echo
echo "============================================================"
echo "5. DISABLE IPV6"
echo "============================================================"

cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

echo
echo "============================================================"
echo "6. BBR + HIGH CONNECTION"
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

echo
echo "============================================================"
echo "7. SYSTEM LIMIT"
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

echo
echo "============================================================"
echo "8. DIRECTORY SING-BOX"
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
    "$RULE_DIR" \
    /var/lib/sing-box \
    /var/log/sing-box

touch /var/log/sing-box/sing-box.log

chown -R sing-box:sing-box \
    /var/lib/sing-box \
    /var/log/sing-box

chmod 755 /var/log/sing-box
chmod 664 /var/log/sing-box/sing-box.log

echo
echo "============================================================"
echo "9. DOWNLOAD GEOSITE.DAT"
echo "============================================================"

rm -rf "$WORK"

mkdir -p \
    "$WORK/txt" \
    "$WORK/json" \
    "$WORK/srs"

wget \
    --tries=3 \
    --timeout=30 \
    -O "$WORK/geosite.dat" \
    "$GEOSITE_URL"

if [ ! -s "$WORK/geosite.dat" ]; then
    echo "ERROR: geosite.dat gagal didownload."
    exit 1
fi

ls -lh "$WORK/geosite.dat"

echo
echo "============================================================"
echo "10. BUILD V2DAT DARI SOURCE"
echo "============================================================"

rm -rf /tmp/v2dat-src

git clone \
https://github.com/urlesistiana/v2dat.git \
/tmp/v2dat-src

cd /tmp/v2dat-src

echo
echo "Go version:"
go version

echo
echo "Build v2dat..."

go build -o /usr/local/bin/v2dat .

chmod +x /usr/local/bin/v2dat

echo
echo "v2dat:"
/usr/local/bin/v2dat --help

echo
echo "============================================================"
echo "11. EXTRACT SEMUA KATEGORI GEOSITE"
echo "============================================================"

rm -rf "$WORK/txt"
mkdir -p "$WORK/txt"

v2dat unpack geosite \
    -d "$WORK/txt" \
    "$WORK/geosite.dat"

TXT_COUNT="$(
    find "$WORK/txt" \
        -type f \
        -name '*.txt' \
        | wc -l
)"

echo
echo "Jumlah kategori geosite.dat: $TXT_COUNT"

if [ "$TXT_COUNT" -eq 0 ]; then
    echo "ERROR: Tidak ada kategori geosite."
    exit 1
fi

echo
echo "============================================================"
echo "12. CONVERT SEMUA KATEGORI KE SRS"
echo "============================================================"

SUCCESS=0
FAILED=0

while IFS= read -r -d '' FILE
do

    BASE="$(basename "$FILE" .txt)"

    NAME="${BASE#geosite_}"
    NAME="${NAME#geosite-}"

    JSON="$WORK/json/${NAME}.json"
    SRS="$WORK/srs/${NAME}.srs"

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

            value = line[5:].strip()

            if value:
                domain.add(value)

        elif line.startswith("domain:"):

            value = line[7:].strip()

            if value:
                domain_suffix.add(value)

        elif line.startswith("keyword:"):

            value = line[8:].strip()

            if value:
                domain_keyword.add(value)

        elif line.startswith("regexp:"):

            value = line[7:].strip()

            if value:
                domain_regex.add(value)

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

    if sing-box rule-set compile \
        "$JSON" \
        -o "$SRS" >/dev/null 2>&1
    then

        echo "  OK: ${NAME}.srs"
        SUCCESS=$((SUCCESS + 1))

    else

        echo "  GAGAL: $NAME"
        FAILED=$((FAILED + 1))
        rm -f "$SRS"

    fi

done < <(
    find "$WORK/txt" \
        -type f \
        -name '*.txt' \
        -print0
)

SRS_COUNT="$(
    find "$WORK/srs" \
        -type f \
        -name '*.srs' \
        | wc -l
)"

echo
echo "Kategori TXT : $TXT_COUNT"
echo "SRS sukses   : $SUCCESS"
echo "SRS gagal    : $FAILED"
echo "Jumlah SRS   : $SRS_COUNT"

echo
echo "============================================================"
echo "13. COPY SEMUA SRS"
echo "============================================================"

rm -rf "$RULE_DIR"
mkdir -p "$RULE_DIR"

find "$WORK/srs" \
    -type f \
    -name '*.srs' \
    -exec cp -f {} "$RULE_DIR/" \;

chmod 755 "$RULE_DIR"
chmod 644 "$RULE_DIR"/*.srs 2>/dev/null || true

echo
echo "============================================================"
echo "14. BUAT WARP SOCIAL RULE"
echo "============================================================"

python3 - "$WORK/txt" "$WORK/json/warp-social.json" <<'PY'
import os
import re
import sys
import json

src_dir = sys.argv[1]
dst = sys.argv[2]

targets = (
    "meta",
    "whatsapp",
    "facebook",
    "instagram",
    "messenger",
    "threads",
)

domain = set()
domain_suffix = set()
domain_keyword = set()
domain_regex = set()

used_files = []

def wanted(filename):

    name = os.path.splitext(
        os.path.basename(filename)
    )[0].lower()

    name = re.sub(
        r"^geosite[_-]",
        "",
        name
    )

    return any(
        name == target
        or name.startswith(target + "-")
        or name.startswith(target + "_")
        for target in targets
    )

for root, dirs, files in os.walk(src_dir):

    for filename in files:

        if not filename.endswith(".txt"):
            continue

        path = os.path.join(root, filename)

        if not wanted(path):
            continue

        used_files.append(path)

        with open(
            path,
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

                if " @" in line:
                    line = line.split(" @", 1)[0].strip()

                if not line:
                    continue

                if line.startswith("full:"):

                    value = line[5:].strip()

                    if value:
                        domain.add(value)

                elif line.startswith("domain:"):

                    value = line[7:].strip()

                    if value:
                        domain_suffix.add(value)

                elif line.startswith("keyword:"):

                    value = line[8:].strip()

                    if value:
                        domain_keyword.add(value)

                elif line.startswith("regexp:"):

                    value = line[7:].strip()

                    if value:
                        domain_regex.add(value)

                else:

                    domain_suffix.add(line)

fallback = {
    "facebook.com",
    "facebook.net",
    "fb.com",
    "fb.me",
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
    "meta.ai",
    "metacareers.com",

    "browserleaks.com",
}

domain_suffix.update(fallback)

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
    "rules": [rule]
}

with open(dst, "w", encoding="utf-8") as f:

    json.dump(
        result,
        f,
        ensure_ascii=False,
        indent=2
    )

print()
print("Kategori social yang digabung:")

for path in sorted(used_files):
    print(" -", os.path.basename(path))

print()
print("Jumlah kategori:", len(used_files))
print("Domain suffix :", len(domain_suffix))

PY

sing-box rule-set compile \
    "$WORK/json/warp-social.json" \
    -o "$RULE_DIR/warp-social.srs"

chmod 644 "$RULE_DIR/warp-social.srs"

echo
echo "============================================================"
echo "15. INSTALL CLOUDFLARE WARP"
echo "============================================================"

install -d -m 0755 /usr/share/keyrings

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

cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main
EOF

apt-get update
apt-get install -y cloudflare-warp

systemctl enable warp-svc
systemctl restart warp-svc

sleep 3

echo
echo "============================================================"
echo "16. REGISTER WARP"
echo "============================================================"

warp-cli disconnect >/dev/null 2>&1 || true

if ! warp-cli registration show >/dev/null 2>&1
then

    yes | warp-cli registration new || true

    sleep 3

fi

warp-cli registration show || true

echo
echo "============================================================"
echo "17. WARP PROXY MODE"
echo "============================================================"

warp-cli mode proxy

warp-cli proxy port "$WARP_PORT"

warp-cli connect

sleep 5

warp-cli status || true

echo
echo "============================================================"
echo "18. TEST WARP"
echo "============================================================"

WARP_TRACE="$(
    curl \
        -sS \
        --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
        --max-time 20 \
        https://www.cloudflare.com/cdn-cgi/trace \
        2>/dev/null || true
)"

echo "$WARP_TRACE" \
    | grep -E '^(ip|colo|warp)=' \
    || true

if ! echo "$WARP_TRACE" | grep -q '^warp=on'
then

    echo
    echo "ERROR: WARP belum aktif."
    warp-cli status || true
    exit 1

fi

echo
echo "WARP = AKTIF"

echo
echo "============================================================"
echo "19. CONFIG SING-BOX"
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
    },

    {
      "type": "socks",
      "tag": "warp",
      "server": "127.0.0.1",
      "server_port": ${WARP_PORT}
    }
  ],

  "route": {

    "rule_set": [
      {
        "type": "local",
        "tag": "warp-social",
        "format": "binary",
        "path": "${RULE_DIR}/warp-social.srs"
      }
    ],

    "rules": [
      {
        "ip_version": 6,
        "action": "reject"
      },

      {
        "rule_set": [
          "warp-social"
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

sing-box check \
    -c /etc/sing-box/config.json

echo
echo "============================================================"
echo "20. SYSTEMD SING-BOX"
echo "============================================================"

cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box Proxy Service
After=network-online.target warp-svc.service
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

sleep 3

if ! systemctl is-active --quiet sing-box
then

    journalctl \
        -u sing-box \
        -n 100 \
        --no-pager

    exit 1

fi

echo
echo "============================================================"
echo "21. NGINX HTTP"
echo "============================================================"

rm -f /etc/nginx/sites-enabled/default

mkdir -p /var/www/html/.well-known/acme-challenge

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {
    listen 80 default_server;

    server_name ${DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 200 "sing-box server\n";
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
echo "22. CERTBOT"
echo "============================================================"

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]
then

    certbot certonly \
        --webroot \
        -w /var/www/html \
        -d "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email

fi

echo
echo "============================================================"
echo "23. NGINX TLS + WEBSOCKET"
echo "============================================================"

cat > /etc/nginx/sites-available/singbox.conf <<EOF
server {
    listen 80 default_server;

    server_name ${DOMAIN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2 default_server;

    server_name ${DOMAIN} _;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;

    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:50m;

    ssl_session_timeout 1d;

    client_max_body_size 0;

    location /trojan {

        proxy_pass http://127.0.0.1:${TROJAN_PORT};

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;

        proxy_read_timeout 86400s;

        proxy_send_timeout 86400s;

        proxy_buffering off;
    }

    location /vmess {

        proxy_pass http://127.0.0.1:${VMESS_PORT};

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;

        proxy_read_timeout 86400s;

        proxy_send_timeout 86400s;

        proxy_buffering off;
    }

    location /vless {

        proxy_pass http://127.0.0.1:${VLESS_PORT};

        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;

        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;

        proxy_read_timeout 86400s;

        proxy_send_timeout 86400s;

        proxy_buffering off;
    }

    location / {

        return 200 "OK\n";
    }
}
EOF

nginx -t

systemctl restart nginx

echo
echo "============================================================"
echo "24. FIREWALL"
echo "============================================================"

ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true

echo
echo "============================================================"
echo "25. FINAL CHECK"
echo "============================================================"

systemctl restart warp-svc

sleep 2

warp-cli connect >/dev/null 2>&1 || true

sleep 3

systemctl restart sing-box
systemctl restart nginx

sleep 3

echo
echo "===== SERVICE ====="

systemctl is-active sing-box || true
systemctl is-active nginx || true
systemctl is-active warp-svc || true

echo
echo "===== WARP ====="

warp-cli status || true

echo
echo "===== PORT ====="

ss -lntp \
| grep -E \
":22 |:80 |:443 |:10001|:10002|:10003|:40000" \
|| true

echo
echo "===== DEFAULT ROUTE VPS ====="

ip route show default

echo
echo "===== IP VPS DIRECT ====="

curl \
    -4 \
    -sS \
    --max-time 15 \
    https://api.ipify.org \
    || true

echo

echo
echo "===== IP WARP ====="

curl \
    -sS \
    --proxy socks5h://127.0.0.1:40000 \
    --max-time 20 \
    https://api.ipify.org \
    || true

echo

echo
echo "===== WARP TRACE ====="

curl \
    -sS \
    --proxy socks5h://127.0.0.1:40000 \
    --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace \
    | grep -E '^(ip|colo|warp)=' \
    || true

echo
echo "===== SRS ====="

echo "Kategori TXT : $TXT_COUNT"
echo "SRS sukses   : $SUCCESS"
echo "SRS gagal    : $FAILED"

echo
echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"
echo
echo "Domain      : $DOMAIN"
echo "UUID        : $UUID"
echo "Trojan Pass : $TROJAN_PASS"
echo
echo "Trojan      : /trojan"
echo "VMess       : /vmess"
echo "VLESS       : /vless"
echo "TLS Port    : 443"
echo
echo "WARP        : 127.0.0.1:40000"
echo
echo "ROUTE VIA WARP:"
echo "  Meta"
echo "  WhatsApp"
echo "  Facebook"
echo "  Instagram"
echo "  Messenger"
echo "  Threads"
echo "  browserleaks.com"
echo
echo "Trafik lainnya:"
echo "  DIRECT"
echo
echo "SSH:"
echo "  Tetap lewat IP asli VPS"
echo
echo "Rule-set:"
echo "  $RULE_DIR/warp-social.srs"
echo
echo "Semua SRS:"
echo "  $RULE_DIR/"
echo
echo "============================================================"

INSTALLER

chmod +x /root/install-singbox-warp.sh

/root/install-singbox-warp.sh
