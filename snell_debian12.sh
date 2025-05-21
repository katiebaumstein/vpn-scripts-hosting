

################################### (paste and "dd" this line in vim)
#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
VERSION="v4.1.1"
URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-amd64.zip"
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/snell"
CONF_FILE="${CONF_DIR}/snell-server.conf"
SERVICE_FILE="/etc/systemd/system/snell.service"
# ────────────────────────────────────────────────────────────────────────────────

# Make apt non-interactive and auto-keep local configs
export DEBIAN_FRONTEND=noninteractive

echo "→ Updating OS and installing prerequisites…"
apt-get update
apt-get -y upgrade \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get install -y wget unzip curl

echo "→ Creating dedicated snell user…"
if ! id snell &>/dev/null; then
  adduser --system \
          --no-create-home \
          --disabled-login \
          --shell /usr/sbin/nologin \
          --group \
          snell
fi

echo "→ Downloading & installing Snell binary…"
cd /tmp
wget -q "$URL"
unzip -o "snell-server-${VERSION}-linux-amd64.zip"
chmod +x snell-server
mv snell-server "$BIN_DIR/"

echo "→ Generating Snell config via wizard (output errors ignored)…"
mkdir -p "$CONF_DIR"
yes | "$BIN_DIR/snell-server" --wizard -c "$CONF_FILE" || true

echo "→ Locking down config permissions…"
chown root:snell "$CONF_FILE"
chmod 640       "$CONF_FILE"

echo "→ Creating systemd unit at $SERVICE_FILE…"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Snell Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

echo "→ Reloading systemd, enabling & starting service…"
systemctl daemon-reload
systemctl enable snell
systemctl start  snell

echo "→ Verifying snell.service status:"
systemctl status snell --no-pager

echo
echo "→ Parsing port & PSK from config:"
RAW_LISTEN=$(grep -E '^\s*listen' "$CONF_FILE" \
             | awk -F'=' '{print $2}' | tr -d ' "')
PORT="${RAW_LISTEN##*:}"
PSK=$(grep -E '^\s*psk' "$CONF_FILE" \
     | awk -F'=' '{print $2}' | tr -d ' "')
SERVER_IP=$(
  curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 \
  || hostname -I | awk '{print $1}'
)

# ─── Big, eye-catching summary ────────────────────────────────────────────────
cat <<EOF

+=================================================+
|               SNELL SERVER INFO                |
+-------------------------------------------------+
| Server IP : ${SERVER_IP}
| Port      : ${PORT}
| PSK       : ${PSK}
+=================================================+

Please ensure TCP port ${PORT} is open both on this host’s firewall
and in your AWS Security Group before connecting.
EOF

# ─── Persist credentials to /etc/motd ────────────────────────────────────────
cat > /etc/motd <<EOF
+=================================================+
|               SNELL SERVER INFO                |
+-------------------------------------------------+
| Server IP : ${SERVER_IP}
| Port      : ${PORT}
| PSK       : ${PSK}
+-------------------------------------------------+
| These will display every time you SSH in!      |
+=================================================+
EOF

# ─── Reboot to finalize everything ────────────────────────────────────────
echo
echo "→ Rebooting now to apply all changes…"
reboot

