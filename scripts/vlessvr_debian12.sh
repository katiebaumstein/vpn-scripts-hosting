
################################### (Paste this line too)

#!/usr/bin/env bash
set -eo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
DEST_DOMAIN="images.ctfassets.net"
VLESS_PORT=443
HTTP_PORT=80
LOGFILE="/var/log/xray-reality-install.log"

RED="\e[1;31m"; GREEN="\e[1;32m"; NC="\e[0m";

# ─── Helpers ──────────────────────────────────────────────────────────────────
die(){
  echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOGFILE" >&2
  exit 1
}
run_step(){
  local desc="$1"; shift
  echo -e "\n→ ${desc}..." | tee -a "$LOGFILE"
  if "$@" 2>&1 | tee -a "$LOGFILE"; then
    echo -e "${GREEN}✔ ${desc} completed${NC}" | tee -a "$LOGFILE"
  else
    die "${desc} failed (see $LOGFILE)"
  fi
}

# ─── 0. Must be root ─────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "Run as root"
> "$LOGFILE"

# ─── 1. System Update & Prerequisites ──────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
run_step "Updating OS & installing prerequisites" bash -c "
  apt-get update &&
  apt-get -y upgrade \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' &&
  apt-get install -y wget unzip curl vim
"

# ─── 2. Install Xray-core ───────────────────────────────────────────────────────
run_step "Installing Xray-core" bash -lc "
  curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    | bash -s -- install -u root
"



# ─── 3. Generate Credentials ───────────────────────────────────────────────────
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"
[ -x "$XRAY_BIN" ] || die "Cannot find xray at $XRAY_BIN"
echo -e "\n→ Using Xray binary: $XRAY_BIN" | tee -a "$LOGFILE"
echo -e "→ Xray version:\n$("$XRAY_BIN" -version 2>&1 || "$XRAY_BIN" version 2>&1)" | tee -a "$LOGFILE"

echo -e "\n→ Generating UUID..." | tee -a "$LOGFILE"
UUID="$("$XRAY_BIN" uuid)" && echo "   $UUID" | tee -a "$LOGFILE" \
  || die "UUID generation failed"

echo -e "\n→ Generating Reality keypair (x25519)..." | tee -a "$LOGFILE"
RAW_KEYS="$("$XRAY_BIN" x25519 2>&1)" \
  && echo -e "   Raw x25519 output:\n$(printf '     %s\n' "$RAW_KEYS")" | tee -a "$LOGFILE" \
  || die "x25519 generation failed"

PRIVATE_KEY=$(printf "%s\n" "$RAW_KEYS" \
  | grep -i 'private key:' | head -n1 | cut -d: -f2- | xargs)
PUBLIC_KEY=$(printf "%s\n" "$RAW_KEYS" \
  | grep -i 'public key:'  | head -n1 | cut -d: -f2- | xargs)
[ -n "$PRIVATE_KEY" ] || die "Could not parse private key"
[ -n "$PUBLIC_KEY"  ] || die "Could not parse public key"

echo -e "${GREEN}✔ PrivateKey:${NC} $PRIVATE_KEY" | tee -a "$LOGFILE"
echo -e "${GREEN}✔ PublicKey: ${NC} $PUBLIC_KEY"  | tee -a "$LOGFILE"

echo -e "\n→ Generating shortID..." | tee -a "$LOGFILE"
SHORT_ID="$(openssl rand -hex 8)" \
  && echo -e "${GREEN}✔ shortID:${NC} $SHORT_ID" | tee -a "$LOGFILE" \
  || die "shortID generation failed"

# ─── 4. Write Xray Configuration ────────────────────────────────────────────────
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
mkdir -p "$CONFIG_DIR"

run_step "Writing Xray config to $CONFIG_FILE" bash -c "cat > '$CONFIG_FILE' <<EOF
{
  \"inbounds\": [
    {
      \"listen\": \"0.0.0.0\",
      \"port\": $VLESS_PORT,
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {\"id\":\"$UUID\",\"flow\":\"xtls-rprx-vision\"}
        ],
        \"decryption\": \"none\",
        \"packetEncoding\": \"xudp\"
      },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${DEST_DOMAIN}:443\",
          \"xver\": 0,
          \"serverNames\": [\"${DEST_DOMAIN}\"],
          \"privateKey\": \"$PRIVATE_KEY\",
          \"shortIds\": [\"$SHORT_ID\"]
        }
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\", \"quic\"],
        \"routeOnly\": true
      },
      \"tag\": \"vless-in\"
    },
    {
      \"listen\": \"0.0.0.0\",
      \"port\": $HTTP_PORT,
      \"protocol\": \"dokodemo-door\",
      \"settings\": {
        \"address\": \"127.0.0.1\",
        \"port\": 8080,
        \"network\": \"tcp\"
      },
      \"tag\": \"http-fallback\"
    }
  ],
  \"outbounds\": [
    {\"protocol\": \"freedom\",   \"settings\": {}, \"tag\": \"direct\"},
    {\"protocol\": \"blackhole\", \"settings\": {}, \"tag\": \"blocked\"}
  ],
  \"routing\": {
    \"rules\": [
      {
        \"type\": \"field\",
        \"ip\": [\"geoip:private\"],
        \"outboundTag\": \"blocked\"
      },
      {
        \"type\": \"field\",
        \"ip\": [\"0.0.0.0/0\", \"::/0\"],
        \"outboundTag\": \"direct\"
      }
    ]
  }
}
EOF
"

# ─── 5. Start & Enable Service ─────────────────────────────────────────────────
run_step "Starting Xray service" systemctl start xray
run_step "Enabling Xray on boot"  systemctl enable xray

# ─── 6. Detect Public IP ────────────────────────────────────────────────────────
echo -e "\n→ Detecting public IP..." | tee -a "$LOGFILE"
SERVER_IP=$(
  curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 \
    || hostname -I | awk '{print $1}'
)
echo -e "${GREEN}✔ Public IP: $SERVER_IP${NC}" | tee -a "$LOGFILE"

# ─── 7. Generate VLESS URL ──────────────────────────────────────────────────────
VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DEST_DOMAIN}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Reality"

# ─── 8. Final Credentials Output ────────────────────────────────────────────────
cat <<EOF | tee -a "$LOGFILE"

+==================================================+
|            Xray VLESS+Reality Credentials        |
+--------------------------------------------------+
| Server IP : $SERVER_IP
| Port      : $VLESS_PORT
| UUID      : $UUID
| PublicKey : $PUBLIC_KEY
| shortID   : $SHORT_ID
+--------------------------------------------------+
| VLESS URL (import into client):                 |
| $VLESS_URL
+==================================================+

Ensure TCP port $VLESS_PORT is open in both this host’s firewall
and your AWS Security Group before connecting.
EOF

# ─── 9. Persist credentials to motd for every SSH login ────────────────────────
cat > /etc/motd <<EOF
+==================================================+
|            Xray VLESS+Reality Credentials        |
+--------------------------------------------------+
| Server IP : $SERVER_IP
| Port      : $VLESS_PORT
| UUID      : $UUID
| PublicKey : $PUBLIC_KEY
| shortID   : $SHORT_ID
| Config    : /usr/local/etc/xray/config.json
+--------------------------------------------------+
| VLESS URL (import into client):                 |
| $VLESS_URL
+==================================================+
EOF

# ─── 10. Reboot to finalize everything ───────────────────────────────────────────
echo -e "\n→ Rebooting now to apply all changes..." | tee -a "$LOGFILE"
reboot
