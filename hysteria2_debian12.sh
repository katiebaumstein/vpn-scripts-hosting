
##################### (Paste this line  and "dd" in vim on this line)

#!/usr/bin/env bash
set -euo pipefail

# ─── Make APT Non-Interactive & Keep Local Configs ─────────────────────────────
export DEBIAN_FRONTEND=noninteractive

# ─── 1. INTERACTIVE PROMPTS ───────────────────────────────────────────────────
if [[ -z "${DOMAIN_NAME:-}" ]]; then
  read -rp "Enter your Hysteria domain (e.g. hy2.example.com): " DOMAIN_NAME
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
fi

# ─── 3. SYSTEM PREP ───────────────────────────────────────────────────────────
echo
echo "Updating OS and installing prerequisites…"
apt-get update
apt-get -y upgrade \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"
apt-get install -y ufw curl

echo "Opening UDP/443 in UFW…"
ufw allow 443/udp

# ─── 4. INSTALL HYSTERIA2 ─────────────────────────────────────────────────────
echo
echo "→ Installing Hysteria2…"
bash <(curl -fsSL https://get.hy2.sh/)

# ─── 5. EXTRACT GENERATED PASSWORD ────────────────────────────────────────────
CONFIG_FILE="/etc/hysteria/config.yaml"
if [[ ! -f $CONFIG_FILE ]]; then
  echo "Could not find $CONFIG_FILE — installation may have failed."
  exit 1
fi

HYSTERIA_PW=$(grep -m1 -E '^\s*password:' "$CONFIG_FILE" | awk '{print $2}')
if [[ -z "$HYSTERIA_PW" ]]; then
  echo "Failed to extract password from $CONFIG_FILE."
  exit 1
fi
echo "Retrieved Hysteria password: $HYSTERIA_PW"

# ─── 6. WRITE FINAL CONFIG.YAML ──────────────────────────────────────────────
cat > "$CONFIG_FILE" <<EOF
listen: :443

acme:
  domains:
    - ${DOMAIN_NAME}
  email: ${DOMAIN_EMAIL}

auth:
  type: password
  password: ${HYSTERIA_PW}

masquerade:
  type: proxy
  proxy:
    url: https://images.ctfassets.net/
    rewriteHost: true
EOF

# ─── 7. ENABLE & START SERVICE ───────────────────────────────────────────────
echo
echo "→ Enabling & restarting Hysteria2 service…"
systemctl daemon-reload
systemctl enable hysteria-server.service
systemctl restart hysteria-server.service

# ─── 8. PERSIST CREDENTIALS TO /etc/motd ──────────────────────────────────────
cat > /etc/motd <<EOF
+==================================================+
|               Hysteria2 Credentials              |
+--------------------------------------------------+
| Server IP : $SERVER_IP
| Domain    : $DOMAIN_NAME
| Port      : 443/udp
| Password  : $HYSTERIA_PW
| Config    : $CONFIG_FILE
+--------------------------------------------------+
|  These will display every time you SSH in!      |
+==================================================+
EOF

# ─── 9. REBOOT TO FINALIZE EVERYTHING ────────────────────────────────────────
echo
echo "Rebooting now to apply all changes…"
reboot
