cat > /root/install-ssh-ws.sh <<'INSTALLER'
#!/bin/bash
set -e

# ============================================================
# OpenSSH + HTTP Upgrade/WebSocket + TLS
# Debian 12
#
# Client:
# SSH   : DOMAIN:443@mashen:mashen
# Proxy : 104.17.70.206:80
#
# Compatible payload:
# GET / HTTP/1.1[crlf]
# Host: edu.ruangguru.com[crlf][crlf]
# PATCH / HTTP/1.1[crlf]
# Host: [host][crlf]
# Upgrade: websocket[crlf][crlf]
# [split]
# HTTP/ 69[crlf][crlf]
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: jalankan script sebagai root."
    exit 1
fi

clear

echo "============================================================"
echo "      SSH WS TLS INSTALLER - DEBIAN 12"
echo "============================================================"
echo

read -rp "Masukkan domain SSH: " DOMAIN

DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN,,}"
DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]')"

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain tidak boleh kosong."
    exit 1
fi

USERNAME="mashen"
PASSWORD="mashen"

SSH_PORT="22"
WS_PORT="8880"

echo
echo "============================================================"
echo " KONFIGURASI"
echo "============================================================"
echo
echo "Domain   : $DOMAIN"
echo "Username : $USERNAME"
echo "Password : $PASSWORD"
echo
sleep 2

# ============================================================
# SYSTEM
# ============================================================

export DEBIAN_FRONTEND=noninteractive

echo
echo "============================================================"
echo " 1. UPDATE SYSTEM"
echo "============================================================"

apt-get update

apt-get install -y \
    openssh-server \
    openssh-client \
    nginx \
    certbot \
    python3-certbot-nginx \
    python3 \
    curl \
    wget \
    ca-certificates \
    netcat-openbsd \
    openssl \
    socat \
    iproute2 \
    net-tools \
    cron

# ============================================================
# TIMEZONE
# ============================================================

echo
echo "============================================================"
echo " 2. TIMEZONE"
echo "============================================================"

timedatectl set-timezone Asia/Jakarta || true

# ============================================================
# CREATE SSH USER
# ============================================================

echo
echo "============================================================"
echo " 3. CREATE SSH USER"
echo "============================================================"

if id "$USERNAME" >/dev/null 2>&1; then
    echo "User $USERNAME sudah ada."
else
    useradd \
        --create-home \
        --shell /bin/bash \
        "$USERNAME"
fi

echo "${USERNAME}:${PASSWORD}" | chpasswd

# ============================================================
# SSH CONFIG
# ============================================================

echo
echo "============================================================"
echo " 4. CONFIGURE OPENSSH"
echo "============================================================"

mkdir -p /etc/ssh/sshd_config.d

if [ -f /etc/ssh/sshd_config ]; then
    cp -a \
        /etc/ssh/sshd_config \
        "/etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"
fi

cat > /etc/ssh/sshd_config.d/99-ssh-custom.conf <<'EOF'
Port 22

PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes

PermitRootLogin prohibit-password

AllowTcpForwarding yes
AllowAgentForwarding yes
GatewayPorts yes

TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3

MaxSessions 100
MaxStartups 100:30:200

LoginGraceTime 60

UseDNS no

X11Forwarding no

Banner /etc/ssh/banner
EOF

cat > /etc/ssh/banner <<'EOF'

========================================
<br>
<br>
<br>
<br>
<br>
HENDRA ARAP x RISMA CANTIK
<br>
<br>
<br>
<br>
<br>
========================================

EOF

sshd -t

systemctl enable ssh
systemctl restart ssh

# ============================================================
# SSH HTTP UPGRADE BRIDGE
# ============================================================

echo
echo "============================================================"
echo " 5. INSTALL SSH HTTP UPGRADE BRIDGE"
echo "============================================================"

mkdir -p /opt/ssh-ws

cat > /opt/ssh-ws/ssh-ws.py <<'PYTHON'
#!/usr/bin/env python3

import asyncio

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8880

SSH_HOST = "127.0.0.1"
SSH_PORT = 22

HEADER_TIMEOUT = 20
SSH_IDENT_TIMEOUT = 30

MAX_HEADER = 131072
MAX_PRE_SSH = 131072


async def raw_relay(reader, writer):
    """
    Raw TCP forwarding after SSH identification has started.
    """

    try:
        while True:

            data = await reader.read(65536)

            if not data:
                break

            writer.write(data)

            await writer.drain()

    except (
        asyncio.CancelledError,
        ConnectionResetError,
        BrokenPipeError
    ):
        pass


async def server_to_client(ssh_reader, client_writer):
    """
    Forward OpenSSH server data directly to the client.
    """

    try:

        while True:

            data = await ssh_reader.read(65536)

            if not data:
                break

            client_writer.write(data)

            await client_writer.drain()

    except (
        asyncio.CancelledError,
        ConnectionResetError,
        BrokenPipeError
    ):
        pass


async def client_to_ssh_filtered(
    client_reader,
    ssh_writer,
    initial=b""
):
    """
    Important compatibility filter.

    HTTP Custom payload can send extra data after HTTP 101,
    for example:

        HTTP/ 69\r\n\r\n

    because it is transmitted using [split].

    That data MUST NOT reach OpenSSH.

    Wait until the actual SSH identification string:

        SSH-2.0-...

    is received.

    Everything before "SSH-" is discarded.

    After SSH identification is found, traffic becomes
    a completely raw TCP tunnel.
    """

    buf = initial

    try:

        while True:

            pos = buf.find(b"SSH-")

            if pos >= 0:

                ssh_data = buf[pos:]

                if ssh_data:

                    ssh_writer.write(ssh_data)

                    await ssh_writer.drain()

                print(
                    "SSH client identification detected; "
                    f"discarded {pos} pre-SSH bytes",
                    flush=True
                )

                # After the SSH identification starts,
                # do NOT filter anything anymore.
                await raw_relay(
                    client_reader,
                    ssh_writer
                )

                return

            if len(buf) > MAX_PRE_SSH:

                print(
                    "Too much data received before SSH identification.",
                    flush=True
                )

                return

            chunk = await asyncio.wait_for(
                client_reader.read(4096),
                timeout=SSH_IDENT_TIMEOUT
            )

            if not chunk:
                return

            buf += chunk

            # Prevent excessive memory growth while retaining
            # enough bytes to detect a split "SSH-" prefix.
            if len(buf) > 32768:
                buf = buf[-32768:]

    except asyncio.TimeoutError:

        print(
            "Timeout waiting for SSH client identification.",
            flush=True
        )

    except (
        asyncio.CancelledError,
        ConnectionResetError,
        BrokenPipeError
    ):
        pass


async def read_http_request(reader):

    buf = b""

    while b"\r\n\r\n" not in buf:

        chunk = await asyncio.wait_for(
            reader.read(4096),
            timeout=HEADER_TIMEOUT
        )

        if not chunk:
            return None, b""

        buf += chunk

        if len(buf) > MAX_HEADER:
            return None, b""

    headers, leftover = buf.split(
        b"\r\n\r\n",
        1
    )

    return headers, leftover


async def handle(
    client_reader,
    client_writer
):

    ssh_writer = None

    peer = client_writer.get_extra_info(
        "peername"
    )

    try:

        headers, leftover = await read_http_request(
            client_reader
        )

        if headers is None:
            return

        request = headers.decode(
            "latin1",
            errors="ignore"
        )

        lines = request.split("\r\n")

        first_line = (
            lines[0]
            if lines
            else "UNKNOWN"
        )

        print(
            f"{peer} request: {first_line}",
            flush=True
        )

        lower = request.lower()

        # Require an HTTP Upgrade request.
        if "upgrade:" not in lower:

            client_writer.write(
                b"HTTP/1.1 400 Bad Request\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n"
                b"\r\n"
            )

            await client_writer.drain()

            return

        # Connect to local OpenSSH.
        ssh_reader, ssh_writer = (
            await asyncio.open_connection(
                SSH_HOST,
                SSH_PORT
            )
        )

        # IMPORTANT:
        # Return exactly ONE HTTP response.
        client_writer.write(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Connection: Upgrade\r\n"
            b"Upgrade: websocket\r\n"
            b"\r\n"
        )

        await client_writer.drain()

        # OpenSSH -> client
        s2c = asyncio.create_task(
            server_to_client(
                ssh_reader,
                client_writer
            )
        )

        # Client -> OpenSSH
        #
        # Filter extra HTTP Custom [split] bytes before
        # the real SSH client identification string.
        c2s = asyncio.create_task(
            client_to_ssh_filtered(
                client_reader,
                ssh_writer,
                leftover
            )
        )

        done, pending = await asyncio.wait(
            [c2s, s2c],
            return_when=asyncio.FIRST_COMPLETED
        )

        for task in pending:
            task.cancel()

        await asyncio.gather(
            *pending,
            return_exceptions=True
        )

    except asyncio.TimeoutError:

        print(
            f"{peer}: HTTP header timeout",
            flush=True
        )

    except Exception as e:

        print(
            f"{peer}: {repr(e)}",
            flush=True
        )

    finally:

        try:

            if ssh_writer:

                ssh_writer.close()

                await ssh_writer.wait_closed()

        except Exception:
            pass

        try:

            client_writer.close()

            await client_writer.wait_closed()

        except Exception:
            pass


async def main():

    server = await asyncio.start_server(
        handle,
        LISTEN_HOST,
        LISTEN_PORT,
        reuse_address=True,
        backlog=4096
    )

    print(
        f"SSH HTTP Upgrade bridge listening "
        f"on {LISTEN_HOST}:{LISTEN_PORT}",
        flush=True
    )

    async with server:

        await server.serve_forever()


if __name__ == "__main__":

    asyncio.run(main())
PYTHON

chmod 755 /opt/ssh-ws/ssh-ws.py

# ============================================================
# SYSTEMD SSH-WS
# ============================================================

cat > /etc/systemd/system/ssh-ws.service <<'EOF'
[Unit]
Description=SSH HTTP Upgrade Bridge
After=network-online.target ssh.service
Wants=network-online.target
Requires=ssh.service

[Service]
Type=simple

User=root
Group=root

ExecStart=/usr/bin/python3 /opt/ssh-ws/ssh-ws.py

Restart=always
RestartSec=2

LimitNOFILE=1048576
TasksMax=infinity

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

systemctl enable ssh-ws
systemctl restart ssh-ws

sleep 2

if ! systemctl is-active --quiet ssh-ws; then

    echo
    echo "ERROR: ssh-ws gagal start."
    echo

    journalctl \
        -u ssh-ws \
        --no-pager \
        -n 50

    exit 1
fi

# ============================================================
# NGINX GLOBAL TUNING
# ============================================================

echo
echo "============================================================"
echo " 6. CONFIGURE NGINX"
echo "============================================================"

cp -a \
    /etc/nginx/nginx.conf \
    "/etc/nginx/nginx.conf.backup.$(date +%Y%m%d-%H%M%S)"

cat > /etc/nginx/nginx.conf <<'NGINX'
user www-data;

worker_processes auto;

worker_rlimit_nofile 1048576;

pid /run/nginx.pid;

include /etc/nginx/modules-enabled/*.conf;

events {

    worker_connections 65535;

    multi_accept on;

    use epoll;
}

http {

    sendfile on;

    tcp_nopush on;
    tcp_nodelay on;

    keepalive_timeout 65;
    keepalive_requests 100000;

    types_hash_max_size 2048;

    server_tokens off;

    client_max_body_size 100m;

    include /etc/nginx/mime.types;

    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip off;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINX

# Remove default/conflicting sites on a fresh install.
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default

rm -f /etc/nginx/sites-enabled/ssh-ws.conf
rm -f /etc/nginx/sites-available/ssh-ws.conf

# ============================================================
# TEMPORARY HTTP SERVER FOR CERTBOT
# ============================================================

cat > /etc/nginx/sites-available/ssh-ws.conf <<EOF
server {

    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    location / {

        proxy_pass http://127.0.0.1:$WS_PORT;

        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

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
}
EOF

ln -s \
    /etc/nginx/sites-available/ssh-ws.conf \
    /etc/nginx/sites-enabled/ssh-ws.conf

nginx -t

systemctl enable nginx
systemctl restart nginx

# ============================================================
# DNS CHECK
# ============================================================

echo
echo "============================================================"
echo " 7. DNS CHECK"
echo "============================================================"

SERVER_IP="$(
    curl -4 -s \
    --max-time 10 \
    https://api.ipify.org \
    || true
)"

echo
echo "VPS IP : ${SERVER_IP:-UNKNOWN}"
echo "Domain : $DOMAIN"
echo

getent ahostsv4 "$DOMAIN" 2>/dev/null \
    | awk '{print $1}' \
    | sort -u \
    | head -10 \
    || true

echo

# ============================================================
# CERTIFICATE
# ============================================================

echo
echo "============================================================"
echo " 8. REQUEST LET'S ENCRYPT CERTIFICATE"
echo "============================================================"
echo

if [ \
    -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" \
    ] && [ \
    -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" \
    ]; then

    echo "Certificate sudah tersedia."

else

    certbot certonly \
        --nginx \
        --domain "$DOMAIN" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email

fi

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then

    echo
    echo "============================================================"
    echo " SSL CERTIFICATE GAGAL"
    echo "============================================================"
    echo
    echo "Pastikan:"
    echo "1. Domain mengarah ke IP VPS ini."
    echo "2. Port 80 dari internet terbuka."
    echo "3. Jika perlu, Cloudflare sementara DNS Only."
    echo
    echo "Setelah diperbaiki jalankan ulang:"
    echo
    echo "bash /root/install-ssh-ws.sh"
    echo

    exit 1
fi

# ============================================================
# FINAL NGINX SERVER
# ============================================================

echo
echo "============================================================"
echo " 9. ENABLE PORT 80 + 443"
echo "============================================================"

cat > /etc/nginx/sites-available/ssh-ws.conf <<EOF
# ============================================================
# SSH HTTP UPGRADE - PORT 80
# ============================================================

server {

    listen 80;
    listen [::]:80;

    server_name $DOMAIN;

    location / {

        proxy_pass http://127.0.0.1:$WS_PORT;

        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

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
}

# ============================================================
# SSH HTTP UPGRADE + TLS - PORT 443
# ============================================================

server {

    listen 443 ssl;
    listen [::]:443 ssl;

    server_name $DOMAIN;

    ssl_certificate \
        /etc/letsencrypt/live/$DOMAIN/fullchain.pem;

    ssl_certificate_key \
        /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;

    ssl_session_tickets off;

    location / {

        proxy_pass http://127.0.0.1:$WS_PORT;

        proxy_http_version 1.1;

        proxy_set_header Host \$http_host;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

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
}
EOF

nginx -t

systemctl restart nginx

# ============================================================
# CERTBOT RENEWAL
# ============================================================

echo
echo "============================================================"
echo " 10. CERTBOT AUTO RENEW"
echo "============================================================"

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF

chmod +x \
    /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ============================================================
# TCP TUNING
# ============================================================

echo
echo "============================================================"
echo " 11. TCP TUNING"
echo "============================================================"

cat > /etc/sysctl.d/99-ssh-ws.conf <<'EOF'
fs.file-max = 2097152

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384

net.ipv4.tcp_max_syn_backlog = 16384

net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.tcp_fin_timeout = 30

net.ipv4.ip_local_port_range = 10240 65535
EOF

sysctl --system >/dev/null 2>&1 || true

# ============================================================
# SSH SERVICE LIMITS
# ============================================================

mkdir -p /etc/systemd/system/ssh.service.d

cat > /etc/systemd/system/ssh.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
EOF

mkdir -p /etc/systemd/system/nginx.service.d

cat > /etc/systemd/system/nginx.service.d/limits.conf <<'EOF'
[Service]
LimitNOFILE=1048576
TasksMax=infinity
EOF

systemctl daemon-reload

systemctl restart ssh
systemctl restart ssh-ws
systemctl restart nginx

# ============================================================
# FIREWALL INFORMATION
# ============================================================

echo
echo "============================================================"
echo " 12. PORT CHECK"
echo "============================================================"

echo
echo "Pastikan firewall provider/VPS membuka:"
echo
echo "TCP 22"
echo "TCP 80"
echo "TCP 443"
echo

# ============================================================
# LOCAL BRIDGE TEST
# ============================================================

echo
echo "============================================================"
echo " 13. TEST LOCAL SSH BRIDGE"
echo "============================================================"
echo

TEST_OUTPUT="$(
    timeout 3 bash -c "
        printf 'PATCH / HTTP/1.1\r\nHost: $DOMAIN\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' |
        nc 127.0.0.1 $WS_PORT
    " 2>/dev/null || true
)"

echo "$TEST_OUTPUT" | head -10

if echo "$TEST_OUTPUT" \
    | grep -q "101 Switching Protocols"; then

    echo
    echo "[OK] HTTP Upgrade 101 berhasil."

else

    echo
    echo "[WARNING] 101 tidak terdeteksi."

fi

if echo "$TEST_OUTPUT" \
    | grep -q "SSH-2.0-OpenSSH"; then

    echo "[OK] OpenSSH banner berhasil."
else
    echo "[WARNING] OpenSSH banner tidak terdeteksi."
fi

# ============================================================
# SERVICE CHECK
# ============================================================

echo
echo "============================================================"
echo " 14. SERVICE STATUS"
echo "============================================================"
echo

printf "%-12s : " "SSH"

if systemctl is-active --quiet ssh; then
    echo "ACTIVE"
else
    echo "FAILED"
fi

printf "%-12s : " "SSH-WS"

if systemctl is-active --quiet ssh-ws; then
    echo "ACTIVE"
else
    echo "FAILED"
fi

printf "%-12s : " "NGINX"

if systemctl is-active --quiet nginx; then
    echo "ACTIVE"
else
    echo "FAILED"
fi

echo
echo "Listening ports:"
echo

ss -lntp \
    | grep -E ':22 |:80 |:443 |:8880 ' \
    || true

# ============================================================
# FINISH
# ============================================================

echo
echo
echo "============================================================"
echo "               INSTALLATION SELESAI"
echo "============================================================"
echo
echo "DOMAIN"
echo "  $DOMAIN"
echo
echo "IP VPS"
echo "  ${SERVER_IP:-UNKNOWN}"
echo
echo "OPENSSH"
echo "  Host     : $DOMAIN"
echo "  Port     : 22"
echo "  Username : $USERNAME"
echo "  Password : $PASSWORD"
echo
echo "SSH WS TLS"
echo "  Host     : $DOMAIN"
echo "  Port     : 443"
echo "  Username : $USERNAME"
echo "  Password : $PASSWORD"
echo "  SNI      : $DOMAIN"
echo
echo "SSH WS NON-TLS"
echo "  Host     : $DOMAIN"
echo "  Port     : 80"
echo
echo "============================================================"
echo " HTTP CUSTOM"
echo "============================================================"
echo
echo "SSH:"
echo "$DOMAIN:443@$USERNAME:$PASSWORD"
echo
echo "Proxy:"
echo "104.17.70.206:80"
echo
echo "Payload:"
echo
echo 'GET / HTTP/1.1[crlf]Host: edu.ruangguru.com[crlf][crlf]PATCH / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf][split]HTTP/ 69[crlf][crlf]'
echo
echo "============================================================"
echo " MONITOR"
echo "============================================================"
echo
echo "journalctl -u ssh-ws -f"
echo
echo "tail -f /var/log/nginx/access.log /var/log/nginx/error.log"
echo
echo "============================================================"
INSTALLER

chmod +x /root/install-ssh-ws.sh
bash /root/install-ssh-ws.sh
