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

# ============================================================
# INPUT
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
RULE_DIR="/etc/sing-box/rule-set"

GEOSITE_URL="https://github.com/malikshi/v2ray-rules-dat/releases/download/202602081243/geosite.dat"

export DEBIAN_FRONTEND=noninteractive

echo
echo "============================================================"
echo " DOMAIN"
echo "============================================================"
echo
echo "Domain      : $DOMAIN"
echo "UUID        : $UUID"
echo "Trojan Pass : $TROJAN_PASS"
echo

# ============================================================
# 1. BACKUP
# ============================================================

echo
echo "============================================================"
echo "1. BACKUP"
echo "============================================================"

BACKUP="/root/backup-singbox-$(date +%F-%H%M%S)"

mkdir -p "$BACKUP"

cp -a /etc/nginx "$BACKUP/" 2>/dev/null || true
cp -a /etc/sing-box "$BACKUP/" 2>/dev/null || true
cp -a /etc/resolv.conf "$BACKUP/resolv.conf" 2>/dev/null || true

echo "Backup: $BACKUP"

# ============================================================
# 2. TIMEZONE
# ============================================================

echo
echo "============================================================"
echo "2. TIMEZONE ASIA/JAKARTA"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta

timedatectl | grep "Time zone" || true

# ============================================================
# 3. PACKAGE
# ============================================================

echo
echo "============================================================"
echo "3. INSTALL PACKAGE"
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
    lsb-release

# ============================================================
# 4. NODEJS + PM2
# ============================================================

echo
echo "============================================================"
echo "4. NODEJS 24 + PM2"
echo "============================================================"

curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

apt-get install -y nodejs

npm install -g pm2

node --version || true
npm --version || true
pm2 --version || true

# ============================================================
# 5. INSTALL SING-BOX
# ============================================================

echo
echo "============================================================"
echo "5. INSTALL SING-BOX"
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
# 6. DISABLE IPV6
# ============================================================

echo
echo "============================================================"
echo "6. DISABLE IPV6"
echo "============================================================"

cat > /etc/sysctl.d/10-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

# ============================================================
# 7. DNS
# ============================================================

echo
echo "============================================================"
echo "7. DNS"
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
# 8. BBR + HIGH CONNECTION
# ============================================================

echo
echo "============================================================"
echo "8. BBR + HIGH CONNECTION"
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
# 9. LIMIT
# ============================================================

echo
echo "============================================================"
echo "9. SYSTEM LIMIT"
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
# 10. USER SING-BOX
# ============================================================

echo
echo "============================================================"
echo "10. USER + DIRECTORY SING-BOX"
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

# ============================================================
# 11. DOWNLOAD GEOSITE
# ============================================================

echo
echo "============================================================"
echo "11. DOWNLOAD GEOSITE.DAT"
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

# ============================================================
# 12. INSTALL V2DAT
# ============================================================

echo
echo "============================================================"
echo "12. INSTALL V2DAT"
echo "============================================================"

ARCH="$(uname -m)"

case "$ARCH" in

    x86_64|amd64)
        V2ARCH="amd64"
        ;;

    aarch64|arm64)
        V2ARCH="arm64"
        ;;

    *)
        echo "ERROR: Arsitektur tidak didukung: $ARCH"
        exit 1
        ;;

esac

wget \
    --tries=3 \
    --timeout=30 \
    -O /tmp/v2dat.zip \
    "https://github.com/urlesistiana/v2dat/releases/latest/download/v2dat-linux-${V2ARCH}.zip"

rm -rf /tmp/v2dat-install

mkdir -p /tmp/v2dat-install

unzip \
    -o \
    /tmp/v2dat.zip \
    -d /tmp/v2dat-install

V2DAT_BIN="$(
    find /tmp/v2dat-install \
        -type f \
        -name v2dat \
        | head -1
)"

if [ -z "$V2DAT_BIN" ]; then

    echo "ERROR: binary v2dat tidak ditemukan."
    exit 1

fi

cp "$V2DAT_BIN" /usr/local/bin/v2dat

chmod +x /usr/local/bin/v2dat

v2dat --help | head -30 || true

# ============================================================
# 13. EXTRACT SEMUA KATEGORI GEOSITE
# ============================================================

echo
echo "============================================================"
echo "13. EXTRACT SEMUA KATEGORI GEOSITE"
echo "============================================================"

rm -rf "$WORK/txt"

mkdir -p "$WORK/txt"

v2dat unpack geosite \
    -o "$WORK/txt" \
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

# ============================================================
# 14. CONVERT SEMUA KATEGORI TXT -> JSON -> SRS
# ============================================================

echo
echo "============================================================"
echo "14. CONVERT SEMUA KATEGORI KE .SRS"
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

# ============================================================
# 15. COPY SEMUA SRS
# ============================================================

echo
echo "============================================================"
echo "15. COPY SEMUA .SRS KE SING-BOX"
echo "============================================================"

rm -rf "$RULE_DIR"

mkdir -p "$RULE_DIR"

find "$WORK/srs" \
    -type f \
    -name '*.srs' \
    -exec cp -f {} "$RULE_DIR/" \;

chmod 755 "$RULE_DIR"

chmod 644 "$RULE_DIR"/*.srs 2>/dev/null || true

# ============================================================
# 16. BUAT WARP SOCIAL RULE
# ============================================================

echo
echo "============================================================"
echo "16. BUAT RULE WARP SOCIAL"
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

    for target in targets:
        if (
            name == target
            or name.startswith(target + "-")
            or name.startswith(target + "_")
        ):
            return True

    return False

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
                    line = line.split(
                        " @",
                        1
                    )[0].strip()

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

# Fallback penting agar routing tetap ada
# walaupun nama kategori geosite berbeda.

fallback_suffix = {
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

domain_suffix.update(fallback_suffix)

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

with open(
    dst,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        result,
        f,
        ensure_ascii=False,
        indent=2
    )

print()
print("Kategori geosite yang digabung:")

for path in sorted(used_files):
    print(" - " + os.path.basename(path))

print()
print("Jumlah file geosite social:", len(used_files))
print("Domain full                :", len(domain))
print("Domain suffix              :", len(domain_suffix))
print("Domain keyword             :", len(domain_keyword))
print("Domain regex               :", len(domain_regex))

PY

sing-box rule-set compile \
    "$WORK/json/warp-social.json" \
    -o "$RULE_DIR/warp-social.srs"

chmod 644 "$RULE_DIR/warp-social.srs"

echo
echo "Rule WARP:"
ls -lh "$RULE_DIR/warp-social.srs"

# ============================================================
# 17. INSTALL CLOUDFLARE WARP
# ============================================================

echo
echo "============================================================"
echo "17. INSTALL CLOUDFLARE WARP"
echo "============================================================"

install -d \
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

echo "Codename: $CODENAME"

cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main
EOF

apt-get update

apt-get install -y cloudflare-warp

systemctl enable warp-svc

systemctl restart warp-svc

sleep 3

# ============================================================
# 18. REGISTER WARP
# ============================================================

echo
echo "============================================================"
echo "18. REGISTER WARP"
echo "============================================================"

warp-cli disconnect >/dev/null 2>&1 || true

if ! warp-cli registration show >/dev/null 2>&1
then

    echo "Membuat registrasi WARP..."

    yes | warp-cli registration new || true

    sleep 3

fi

warp-cli registration show || true

# ============================================================
# 19. WARP LOCAL PROXY
# ============================================================

echo
echo "============================================================"
echo "19. WARP LOCAL PROXY :$WARP_PORT"
echo "============================================================"

# Local proxy tidak mengambil default route VPS.
# SSH tetap melalui IP asli VPS.

if warp-cli mode proxy >/dev/null 2>&1
then

    echo "WARP proxy mode: OK"

else

    echo "Mencoba mengaktifkan proxy mode..."

    warp-cli mode proxy || {
        echo
        echo "ERROR: WARP client tidak menerima mode proxy."
        echo
        warp-cli mode --help || true
        exit 1
    }

fi

if warp-cli proxy port "$WARP_PORT" >/dev/null 2>&1
then

    echo "WARP proxy port: $WARP_PORT"

else

    echo
    echo "ERROR: Tidak bisa set WARP proxy port."
    echo
    warp-cli proxy --help || true
    exit 1

fi

warp-cli connect

sleep 5

echo
warp-cli status || true

# ============================================================
# 20. TEST WARP SEBELUM SING-BOX
# ============================================================

echo
echo "============================================================"
echo "20. TEST WARP"
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

if echo "$WARP_TRACE" | grep -q '^warp=on'
then

    echo
    echo "WARP = AKTIF"

else

    echo
    echo "ERROR: WARP proxy belum aktif."
    echo
    echo "Status:"
    warp-cli status || true

    echo
    echo "Port:"
    ss -lntp | grep ":${WARP_PORT}" || true

    exit 1

fi

# ============================================================
# 21. CONFIG SING-BOX
# ============================================================

echo
echo "============================================================"
echo "21. CONFIG SING-BOX"
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
      "server_port": ${WARP_PORT},
      "version": "5"
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
        "domain_suffix": [
          "browserleaks.com",
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
          "metacareers.com"
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

# ============================================================
# 22. VALIDATE SING-BOX
# ============================================================

echo
echo "============================================================"
echo "22. VALIDATE SING-BOX"
echo "============================================================"

if ! /usr/bin/sing-box check \
    -c /etc/sing-box/config.json
then

    echo
    echo "ERROR: Config Sing-box tidak valid."
    exit 1

fi

echo "Sing-box config: VALID"

# ============================================================
# 23. SYSTEMD SING-BOX
# ============================================================

echo
echo "============================================================"
echo "23. SYSTEMD SING-BOX"
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

if ! systemctl is-active --quiet sing-box
then

    echo
    echo "ERROR: sing-box gagal berjalan."

    journalctl \
        -u sing-box \
        -n 100 \
        --no-pager

    exit 1

fi

# ============================================================
# 24. NGINX GLOBAL
# ============================================================

echo
echo "============================================================"
echo "24. CONFIG NGINX"
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
# 25. NGINX HTTP
# ============================================================

echo
echo "============================================================"
echo "25. NGINX HTTP + CERTBOT"
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
# 26. TLS CERTIFICATE
# ============================================================

echo
echo "============================================================"
echo "26. TLS CERTIFICATE"
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

if [ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]
then

    echo
    echo "ERROR: Sertifikat TLS tidak ditemukan."
    exit 1

fi

# ============================================================
# 27. NGINX HTTPS
# ============================================================

echo
echo "============================================================"
echo "27. NGINX HTTPS + WEBSOCKET"
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

# ============================================================
# 28. CERTBOT AUTO RENEW
# ============================================================

echo
echo "============================================================"
echo "28. CERTBOT AUTO RENEW"
echo "============================================================"

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

# ============================================================
# 29. UFW
# ============================================================

echo
echo "============================================================"
echo "29. FIREWALL"
echo "============================================================"

ufw allow 22/tcp || true

ufw allow 80/tcp || true

ufw allow 443/tcp || true

# ============================================================
# 30. LOGROTATE
# ============================================================

echo
echo "============================================================"
echo "30. LOGROTATE"
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

# ============================================================
# 31. FINAL RESTART
# ============================================================

echo
echo "============================================================"
echo "31. FINAL RESTART"
echo "============================================================"

systemctl daemon-reload

systemctl restart warp-svc

sleep 2

warp-cli connect >/dev/null 2>&1 || true

sleep 3

systemctl restart sing-box

systemctl restart nginx

sleep 3

# ============================================================
# 32. VALIDATION
# ============================================================

echo
echo "============================================================"
echo "32. VALIDATION"
echo "============================================================"

sing-box check \
    -c /etc/sing-box/config.json

nginx -t

# ============================================================
# 33. SERVICE STATUS
# ============================================================

echo
echo "============================================================"
echo "33. SERVICE STATUS"
echo "============================================================"

printf "%-15s : " "sing-box"
systemctl is-active sing-box || true

printf "%-15s : " "nginx"
systemctl is-active nginx || true

printf "%-15s : " "warp-svc"
systemctl is-active warp-svc || true

echo
echo "WARP:"
warp-cli status || true

# ============================================================
# 34. PORT
# ============================================================

echo
echo "============================================================"
echo "34. PORT"
echo "============================================================"

ss -lntp \
    | grep -E \
    ":22 |:80 |:443 |:${TROJAN_PORT}|:${VMESS_PORT}|:${VLESS_PORT}|:${WARP_PORT}" \
    || true

# ============================================================
# 35. BBR
# ============================================================

echo
echo "============================================================"
echo "35. BBR"
echo "============================================================"

sysctl \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    || true

# ============================================================
# 36. IPV6
# ============================================================

echo
echo "============================================================"
echo "36. IPV6"
echo "============================================================"

sysctl net.ipv6.conf.all.disable_ipv6 || true

# ============================================================
# 37. DEFAULT ROUTE
# ============================================================

echo
echo "============================================================"
echo "37. DEFAULT ROUTE VPS"
echo "============================================================"

ip route show default

echo
echo "SSH:"
echo "${SSH_CONNECTION:-unknown}"

# ============================================================
# 38. DIRECT VPS IP
# ============================================================

echo
echo "============================================================"
echo "38. IP ASLI VPS"
echo "============================================================"

DIRECT_IP="$(
    curl \
        -4 \
        -sS \
        --max-time 15 \
        https://api.ipify.org \
        2>/dev/null || true
)"

echo "Direct VPS : ${DIRECT_IP:-GAGAL}"

# ============================================================
# 39. WARP IP
# ============================================================

echo
echo "============================================================"
echo "39. IP WARP"
echo "============================================================"

WARP_IP="$(
    curl \
        -sS \
        --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
        --max-time 20 \
        https://api.ipify.org \
        2>/dev/null || true
)"

echo "WARP IP    : ${WARP_IP:-GAGAL}"

# ============================================================
# 40. WARP TRACE
# ============================================================

echo
echo "============================================================"
echo "40. WARP TRACE"
echo "============================================================"

curl \
    -sS \
    --proxy "socks5h://127.0.0.1:${WARP_PORT}" \
    --max-time 20 \
    https://www.cloudflare.com/cdn-cgi/trace \
    2>/dev/null \
    | grep -E '^(ip|colo|warp)=' \
    || true

# ============================================================
# 41. SRS
# ============================================================

echo
echo "============================================================"
echo "41. SRS"
echo "============================================================"

echo "Kategori TXT : $TXT_COUNT"
echo "SRS sukses   : $SUCCESS"
echo "SRS gagal    : $FAILED"

echo
echo "Jumlah SRS di $RULE_DIR:"

find "$RULE_DIR" \
    -type f \
    -name '*.srs' \
    | wc -l

echo
echo "Warp social:"

ls -lh "$RULE_DIR/warp-social.srs"

# ============================================================
# 42. FINISH
# ============================================================

echo
echo "============================================================"
echo " INSTALLASI SELESAI"
echo "============================================================"
echo
echo "Domain      : $DOMAIN"
echo "Trojan Pass : $TROJAN_PASS"
echo "UUID        : $UUID"
echo
echo "Trojan WS   : /trojan"
echo "VMess WS    : /vmess"
echo "VLESS WS    : /vless"
echo
echo "Port TLS    : 443"
echo
echo "WARP SOCKS5 : 127.0.0.1:${WARP_PORT}"
echo
echo "IPv6        : OFF"
echo "IPv4        : ONLY"
echo
echo "DEFAULT ROUTE:"
echo "  DIRECT / IP ASLI VPS"
echo
echo "ROUTING WARP:"
echo "  META"
echo "  WHATSAPP"
echo "  FACEBOOK"
echo "  INSTAGRAM"
echo "  MESSENGER"
echo "  THREADS"
echo "  BROWSERLEAKS.COM"
echo
echo "Semua trafik lainnya:"
echo "  DIRECT"
echo
echo "SSH VPS:"
echo "  TETAP VIA IP ASLI / DEFAULT ROUTE"
echo
echo "GEOSITE:"
echo "  $WORK/geosite.dat"
echo
echo "SEMUA SRS:"
echo "  $RULE_DIR/"
echo
echo "RULE SOCIAL:"
echo "  $RULE_DIR/warp-social.srs"
echo
echo "============================================================"

INSTALLER

chmod +x /root/install-singbox-warp.sh

/root/install-singbox-warp.sh
