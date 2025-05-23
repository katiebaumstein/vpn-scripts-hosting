
################### paste issue vim
#!/usr/bin/env bash
set -euo pipefail

# ─── Make APT Non-Interactive & Keep Local Configs ─────────────────────────────
export DEBIAN_FRONTEND=noninteractive

# ─── 1. INTERACTIVE PROMPTS ───────────────────────────────────────────────────
if [[ -z "${DOMAIN_NAME:-}" ]]; then
  read -rp "Enter your Marzban dashboard domain (e.g. marzban.example.com): " DOMAIN_NAME
fi

# Derive apex domain & ACME email
APEX_DOMAIN=$(echo "$DOMAIN_NAME" | awk -F. '{print $(NF-1)"."$NF}')
DOMAIN_EMAIL="admin@${APEX_DOMAIN}"

echo
echo "Using:"
echo "   Domain name:   $DOMAIN_NAME"
echo "   Apex domain:   $APEX_DOMAIN"
echo "   ACME e-mail:   $DOMAIN_EMAIL"
echo

# ─── 2. DNS CHECK (A & AAAA, with optional skip) ─────────────────────────────
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-false}"
if [[ "$SKIP_DNS_CHECK" != "true" ]]; then
  if ! command -v dig &>/dev/null; then
    echo "→ Installing dnsutils (for dig)…"
    apt-get update
    apt-get install -y dnsutils
  fi

  # detect public IP (v4 preferred, fallback to v6)
  PUBLIC_V4=$(curl -4fsSL https://ifconfig.me || echo "")
  PUBLIC_V6=$(curl -6fsSL https://ifconfig.me || echo "")
  SERVER_IP="${PUBLIC_V4:-$PUBLIC_V6}"

  echo "Checking that ${DOMAIN_NAME} resolves to ${SERVER_IP}"
  for i in {1..30}; do
    ALL_IPS=$( { dig +short A "$DOMAIN_NAME"; dig +short AAAA "$DOMAIN_NAME"; } | tr -d '[:space:]' )
    if echo "$ALL_IPS" | grep -qx "$SERVER_IP"; then
      echo " DNS OK: $DOMAIN_NAME → $SERVER_IP"
      break
    fi
    echo "Waiting for DNS to propagate ($i/30)…"
    sleep 10
    if [[ $i -eq 30 ]]; then
      echo " DNS never pointed to $SERVER_IP."
      echo "   • Fix your A/AAAA record or"
      echo "   • Rerun with SKIP_DNS_CHECK=true to bypass."
      exit 1
    fi
  done
else
  echo "SKIPPING DNS check (SKIP_DNS_CHECK=true)"
  PUBLIC_V4=$(curl -4fsSL https://ifconfig.me || echo "")
  PUBLIC_V6=$(curl -6fsSL https://ifconfig.me || echo "")
  SERVER_IP="${PUBLIC_V4:-$PUBLIC_V6}"
fi

# ─── 3. SYSTEM PREP ───────────────────────────────────────────────────────────
echo
echo "Updating OS and installing prerequisites…"
apt-get update
apt-get -y upgrade \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get install -y ufw curl cron socat

echo "Opening ports 8000/tcp (Dashboard) and 443/tcp (VLESS) in UFW…"
ufw allow 8000/tcp
ufw allow 443/tcp

# ─── 4. INSTALL MARZBAN NON-INTERACTIVELY ────────────────────────────────────
echo
echo "→ Installing Marzban…"

# The Marzban installation script shows logs after installation and appears to "hang"
# We need to run it in background and let it complete, then continue
echo "Installing Marzban (this may take a few minutes)..."

# Run Marzban installation in background with timeout
timeout 300 bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install &
MARZBAN_PID=$!

# Wait for installation to complete (it will show logs, then we continue)
echo "Waiting for Marzban installation..."
sleep 60

# Check if Marzban directory exists (installation completed)
WAIT_COUNT=0
while [[ ! -d "/opt/marzban" ]] && [[ $WAIT_COUNT -lt 10 ]]; do
  echo "Waiting for Marzban installation to complete... ($((WAIT_COUNT + 1))/10)"
  sleep 30
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Kill the background process (this simulates Ctrl+C)
kill $MARZBAN_PID 2>/dev/null || true
sleep 5

# Verify Marzban was installed
if [[ ! -d "/opt/marzban" ]]; then
  echo "❌ Marzban installation failed - /opt/marzban directory not found"
  echo "Trying alternative installation method..."
  
  # Try direct installation without the interactive part
  cd /tmp
  curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh -o marzban_install.sh
  chmod +x marzban_install.sh
  
  # Modify the script to skip interactive parts (if possible)
  sed -i 's/read -p/#read -p/g' marzban_install.sh 2>/dev/null || true
  
  # Run with automatic responses
  echo "y" | timeout 300 ./marzban_install.sh install || true
  sleep 30
  
  if [[ ! -d "/opt/marzban" ]]; then
    echo "❌ Marzban installation completely failed"
    exit 1
  fi
fi

echo "✅ Marzban installed successfully"

# Make sure Docker containers are running
cd /opt/marzban
docker compose up -d
sleep 15

echo "Marzban status check:"
docker ps | grep marzban || echo "Marzban containers not yet visible"

# ─── 5. CREATE CERTIFICATE DIRECTORY ─────────────────────────────────────────
echo
echo "→ Creating certificate directory…"
mkdir -p /var/lib/marzban/certs/
chown -R root:root /var/lib/marzban/certs/
chmod 755 /var/lib/marzban/certs/

# ─── 6. INSTALL ACME.SH & GET SSL CERTIFICATE ────────────────────────────────
echo
echo "→ Installing acme.sh and obtaining SSL certificate…"

# Stop Marzban temporarily to free port 80
cd /opt/marzban
docker compose down 2>/dev/null || true

# Stop other services that might use port 80
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

# Install acme.sh
curl https://get.acme.sh | sh -s email="$DOMAIN_EMAIL"

# Wait a moment for acme.sh to be ready
sleep 3

# Get SSL certificate using standalone mode
echo "→ Obtaining SSL certificate for $DOMAIN_NAME…"
~/.acme.sh/acme.sh \
  --set-default-ca --server letsencrypt \
  --issue --standalone -d "$DOMAIN_NAME" \
  --key-file /var/lib/marzban/certs/key.pem \
  --fullchain-file /var/lib/marzban/certs/fullchain.pem \
  --force

# Verify certificates were created
if [[ ! -f "/var/lib/marzban/certs/key.pem" ]] || [[ ! -f "/var/lib/marzban/certs/fullchain.pem" ]]; then
  echo "❌ SSL certificate generation failed!"
  echo "Checking what we have:"
  ls -la /var/lib/marzban/certs/ || echo "Certs directory doesn't exist"
  ls -la ~/.acme.sh/$DOMAIN_NAME*/ || echo "No acme.sh directory found"
  
  echo "Trying manual certificate copy..."
  if [[ -d ~/.acme.sh/$DOMAIN_NAME ]]; then
    cp ~/.acme.sh/$DOMAIN_NAME/fullchain.cer /var/lib/marzban/certs/fullchain.pem
    cp ~/.acme.sh/$DOMAIN_NAME/$DOMAIN_NAME.key /var/lib/marzban/certs/key.pem
  else
    echo "Certificate generation completely failed. Exiting."
    exit 1
  fi
fi

# Set proper permissions
chmod 600 /var/lib/marzban/certs/key.pem
chmod 644 /var/lib/marzban/certs/fullchain.pem
chown root:root /var/lib/marzban/certs/*

echo "✅ SSL certificates generated successfully"
echo "📋 Certificate files:"
ls -la /var/lib/marzban/certs/

# ─── 7. CONFIGURE MARZBAN FOR SSL ────────────────────────────────────────────
echo
echo "→ Configuring Marzban for SSL…"

# Backup and update .env file
ENV_FILE="/opt/marzban/.env"
if [[ -f "$ENV_FILE" ]]; then
  # Backup original
  cp "$ENV_FILE" "$ENV_FILE.backup.$(date +%s)"
  
  # Update existing file - handle the specific .env format with spaces around =
  # Handle lines like: # UVICORN_SSL_CERTFILE = "/var/lib/marzban/certs/example.com/fullchain.pem"
  sed -i 's|^# UVICORN_SSL_CERTFILE = ".*"|UVICORN_SSL_CERTFILE = "/var/lib/marzban/certs/fullchain.pem"|' "$ENV_FILE"
  sed -i 's|^# UVICORN_SSL_KEYFILE = ".*"|UVICORN_SSL_KEYFILE = "/var/lib/marzban/certs/key.pem"|' "$ENV_FILE"
  sed -i "s|^# XRAY_SUBSCRIPTION_URL_PREFIX = \".*\"|XRAY_SUBSCRIPTION_URL_PREFIX = \"https://$DOMAIN_NAME\"|" "$ENV_FILE"
  
  # Also handle lines that might already be uncommented
  sed -i 's|^UVICORN_SSL_CERTFILE = ".*"|UVICORN_SSL_CERTFILE = "/var/lib/marzban/certs/fullchain.pem"|' "$ENV_FILE"
  sed -i 's|^UVICORN_SSL_KEYFILE = ".*"|UVICORN_SSL_KEYFILE = "/var/lib/marzban/certs/key.pem"|' "$ENV_FILE"
  sed -i "s|^XRAY_SUBSCRIPTION_URL_PREFIX = \".*\"|XRAY_SUBSCRIPTION_URL_PREFIX = \"https://$DOMAIN_NAME\"|" "$ENV_FILE"
  
  # Change port back to 8000 to avoid conflict with VLESS on 443
  sed -i 's|^UVICORN_PORT = 443|UVICORN_PORT = 8000|' "$ENV_FILE"
  sed -i 's|^UVICORN_PORT = "443"|UVICORN_PORT = 8000|' "$ENV_FILE"
  
  # If the lines don't exist at all, add them
  if ! grep -q "UVICORN_SSL_CERTFILE" "$ENV_FILE"; then
    echo 'UVICORN_SSL_CERTFILE = "/var/lib/marzban/certs/fullchain.pem"' >> "$ENV_FILE"
  fi
  if ! grep -q "UVICORN_SSL_KEYFILE" "$ENV_FILE"; then
    echo 'UVICORN_SSL_KEYFILE = "/var/lib/marzban/certs/key.pem"' >> "$ENV_FILE"
  fi
  if ! grep -q "XRAY_SUBSCRIPTION_URL_PREFIX" "$ENV_FILE"; then
    echo "XRAY_SUBSCRIPTION_URL_PREFIX = \"https://$DOMAIN_NAME\"" >> "$ENV_FILE"
  fi
  
  # Ensure port is 8000 (to avoid conflict with VLESS on 443)
  if ! grep -q "UVICORN_PORT = 8000" "$ENV_FILE"; then
    if grep -q "UVICORN_PORT" "$ENV_FILE"; then
      sed -i 's|^UVICORN_PORT.*|UVICORN_PORT = 8000|' "$ENV_FILE"
    else
      echo "UVICORN_PORT = 8000" >> "$ENV_FILE"
    fi
  fi
  
else
  echo "Warning: $ENV_FILE not found. Creating it…"
  cat > "$ENV_FILE" <<EOF
UVICORN_HOST=0.0.0.0
UVICORN_PORT=8000
UVICORN_SSL_CERTFILE=/var/lib/marzban/certs/fullchain.pem
UVICORN_SSL_KEYFILE=/var/lib/marzban/certs/key.pem
XRAY_SUBSCRIPTION_URL_PREFIX=https://$DOMAIN_NAME
XRAY_JSON=/var/lib/marzban/xray_config.json
EOF
fi

echo "📋 Updated .env configuration:"
echo "────────────────────────────────"
grep -E "(UVICORN_SSL_|XRAY_SUBSCRIPTION_URL_PREFIX)" "$ENV_FILE" || echo "SSL settings not found in .env"
echo "────────────────────────────────"

# ─── 8. GENERATE XRAY CONFIGURATION ──────────────────────────────────────────
echo
echo "→ Starting Marzban to generate XRAY configuration…"

# Start Marzban
cd /opt/marzban && docker compose up -d
sleep 20

# Generate UUID and keys
echo "→ Generating XRAY credentials…"
XRAY_UUID=$(docker exec marzban-marzban-1 xray uuid 2>/dev/null || uuidgen)

# Try to get X25519 keys from xray
XRAY_KEYS_OUTPUT=$(docker exec marzban-marzban-1 xray x25519 2>/dev/null || echo "")
if [[ -n "$XRAY_KEYS_OUTPUT" ]]; then
  PRIVATE_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep "Private key:" | cut -d' ' -f3 | tr -d '\r\n')
  PUBLIC_KEY=$(echo "$XRAY_KEYS_OUTPUT" | grep "Public key:" | cut -d' ' -f3 | tr -d '\r\n')
else
  # Fallback to OpenSSL if xray x25519 doesn't work
  PRIVATE_KEY=$(openssl rand -base64 32 | tr -d '\n')
  PUBLIC_KEY=$(openssl rand -base64 32 | tr -d '\n')
fi

SHORT_ID=$(openssl rand -hex 8)

echo "Generated credentials:"
echo "  UUID: $XRAY_UUID"
echo "  Private Key: $PRIVATE_KEY"
echo "  Public Key: $PUBLIC_KEY"
echo "  Short ID: $SHORT_ID"

# ─── 9. CREATE XRAY CONFIG ───────────────────────────────────────────────────
echo
echo "→ Creating XRAY configuration…"
XRAY_CONFIG="/var/lib/marzban/xray_config.json"
cat > "$XRAY_CONFIG" <<EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "packetEncoding": "xudp"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "images.ctfassets.net:443",
          "xver": 0,
          "serverNames": ["images.ctfassets.net"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "vless-in"
    },
    {
      "listen": "0.0.0.0",
      "port": 80,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 8080,
        "network": "tcp"
      },
      "tag": "http-fallback"
    }
  ],
  "outbounds": [
    { "protocol": "freedom",   "settings": {}, "tag": "direct"  },
    { "protocol": "blackhole", "settings": {}, "tag": "blocked" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": ["0.0.0.0/0","::/0"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

echo "✅ XRAY configuration created"

# ─── 10. RESTART SERVICES ────────────────────────────────────────────────────
echo
echo "→ Restarting Marzban services…"
cd /opt/marzban
docker compose down
sleep 5
docker compose up -d
sleep 15

# Verify services
echo "→ Checking Marzban status…"
docker logs marzban-marzban-1 | tail -10

# Test SSL connection
echo "→ Testing SSL connection…"
if curl -k -s --connect-timeout 10 https://localhost:8000/docs > /dev/null; then
  echo "✅ Marzban is responding on HTTPS port 8000"
else
  echo "⚠️  Marzban might not be fully ready yet"
fi

# ─── 11. CREATE ADMIN USER AUTOMATICALLY ─────────────────────────────────────
echo
echo "→ Creating admin user automatically…"
sleep 5

# Create admin user with automatic responses
# The process: username -> password -> repeat password -> telegram ID -> discord webhook
expect_script="/tmp/create_admin.exp"
cat > "$expect_script" <<'EOF'
#!/usr/bin/expect -f
set timeout 30
spawn marzban cli admin create --sudo
expect "Username:"
send "michaelbern\r"
expect "Password:"
send "Digtuc-veqfak-6suxju\r"
expect "Repeat for confirmation:"
send "Digtuc-veqfak-6suxju\r"
expect "Telegram ID*"
send "1111111\r"
expect "Discord webhook*"
send "https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz\r"
expect eof
EOF

# Install expect if not available
if ! command -v expect &> /dev/null; then
  echo "Installing expect for automation..."
  apt-get update
  apt-get install -y expect
fi

# Make expect script executable and run it
chmod +x "$expect_script"
"$expect_script"

# Clean up
rm -f "$expect_script"

echo "✅ Admin user 'michaelbern' created successfully!"

# ─── 11. PERSIST CREDENTIALS TO /etc/motd ─────────────────────────────────────
# ─── 12. PERSIST CREDENTIALS TO /etc/motd ─────────────────────────────────────
cat > /etc/motd <<EOF
+==================================================+
|               Marzban VPN Server                 |
+--------------------------------------------------+
| 🌐 Dashboard Login                               |
| URL      : https://$DOMAIN_NAME:8000/dashboard   |
| Username : michaelbern                           |
| Password : Digtuc-veqfak-6suxju                            |
+--------------------------------------------------+
| 🖥️  Server Details                               |
| Server IP: $SERVER_IP                            |
| Domain   : $DOMAIN_NAME                          |
| Dashboard: Port 8000 (HTTPS)                    |
| VLESS    : Port 443                             |
+--------------------------------------------------+
| ⚡ VLESS Reality Configuration                   |
| Protocol : VLESS + Reality                      |
| Port     : 443                                   |
| UUID     : $XRAY_UUID                            |
| Flow     : xtls-rprx-vision                     |
| Security : reality                               |
| SNI      : images.ctfassets.net                 |
| Dest     : images.ctfassets.net:443             |
| PrivateKey: $PRIVATE_KEY                         |
| ShortId  : $SHORT_ID                            |
+--------------------------------------------------+
| 📁 Important Files                               |
| SSL Certs: /var/lib/marzban/certs/              |
| Config   : /opt/marzban/.env                    |
| XRAY JSON: /var/lib/marzban/xray_config.json   |
+--------------------------------------------------+
| 🔧 Management Commands                           |
| Status   : marzban status                       |
| Restart  : marzban restart                      |
| Logs     : marzban logs                         |
| Update   : marzban update                       |
+--------------------------------------------------+
| Dashboard: https://$DOMAIN_NAME:8000/dashboard   |
+==================================================+
EOF

# ─── 13. FINAL INSTRUCTIONS ──────────────────────────────────────────────────
echo
echo "🎉 Marzban installation completed successfully!"
echo
echo "🔗 Dashboard Access:"
echo "   URL: https://$DOMAIN_NAME:8000/dashboard" 
echo "   Username: michaelbern"
echo "   Password: Digtuc-veqfak-6suxju"
echo
echo "📋 Server Details:"
echo "   Server IP: $SERVER_IP"
echo "   Domain: $DOMAIN_NAME"
echo "   Dashboard Port: 8000 (HTTPS)"
echo "   VLESS Port: 443"
echo
echo "⚡ VLESS Reality Server:"
echo "   Protocol: VLESS + Reality"
echo "   Port: 443"
echo "   UUID: $XRAY_UUID"
echo "   Flow: xtls-rprx-vision"
echo "   Security: reality"
echo "   SNI: images.ctfassets.net"
echo "   Private Key: $PRIVATE_KEY"
echo "   Short ID: $SHORT_ID"
echo
echo "📁 Important Files:"
echo "   • SSL Certificates: /var/lib/marzban/certs/"
echo "   • Configuration: /opt/marzban/.env"
echo "   • XRAY Config: /var/lib/marzban/xray_config.json"
echo
echo "🔧 Management Commands:"
echo "   • Check status: marzban status"
echo "   • Restart: marzban restart"
echo "   • View logs: marzban logs"
echo "   • Update: marzban update"
echo
echo "✅ Ready to use! Access your dashboard at:"
echo "   👉 https://$DOMAIN_NAME:8000/dashboard"
echo
echo "⚠️  Note: Dashboard uses port 8000 to avoid conflict with VLESS on port 443"
echo
echo "🔄 System will reboot in 10 seconds to finalize setup…"
sleep 10
reboot
