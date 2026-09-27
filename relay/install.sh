#!/usr/bin/env bash
# Six Bricks — Interparcel relay installer for Ubuntu 24.04 (Oracle Cloud or AWS Lightsail).
# Run AFTER attaching the static IP:
#   curl -fsSL https://raw.githubusercontent.com/robbiebaskin/sixbricks/main/relay/install.sh | sudo bash
# Optional: use your own domain instead of sslip.io (point its A record at the static IP first):
#   curl -fsSL .../install.sh | sudo DOMAIN=relay.example.com.au bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }

REPO_RAW="https://raw.githubusercontent.com/robbiebaskin/sixbricks/main/relay"
IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
DOMAIN="${DOMAIN:-${IP//./-}.sslip.io}"

echo "== Six Bricks relay installer =="
echo "Public IP:     $IP"
echo "Relay address: https://$DOMAIN"
echo
read -rsp "Paste your Interparcel API key and press Enter (input is hidden): " APIKEY < /dev/tty
echo
[ -n "$APIKEY" ] || { echo "No API key entered - aborting."; exit 1; }

echo "Installing Node.js and Caddy..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q nodejs openssl curl
if ! apt-get install -y -q caddy; then
  apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y -q && apt-get install -y -q caddy
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || { echo "Node 18+ required, found $NODE_MAJOR"; exit 1; }

echo "Installing relay..."
id sixbricks &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin sixbricks
mkdir -p /opt/sixbricks-relay
curl -fsSL "$REPO_RAW/relay.js" -o /opt/sixbricks-relay/relay.js
chmod 644 /opt/sixbricks-relay/relay.js

if [ -f /etc/sixbricks-relay.env ] && grep -q '^RELAY_SECRET=' /etc/sixbricks-relay.env; then
  SECRET="$(grep '^RELAY_SECRET=' /etc/sixbricks-relay.env | cut -d= -f2-)"   # keep existing secret on re-run
else
  SECRET="$(openssl rand -hex 32)"
fi
( umask 077; printf 'INTERPARCEL_API_KEY=%s\nRELAY_SECRET=%s\n' "$APIKEY" "$SECRET" > /etc/sixbricks-relay.env )

cat > /etc/systemd/system/sixbricks-relay.service << 'UNIT'
[Unit]
Description=Six Bricks Interparcel relay
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sixbricks-relay.env
ExecStart=/usr/bin/node /opt/sixbricks-relay/relay.js
Restart=always
RestartSec=3
User=sixbricks
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

# Oracle Cloud's Ubuntu images block every inbound port except SSH at the OS firewall.
# Open 80 (certificate issuance) and 443 (HTTPS) there too.
if iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  echo "Opening ports 80 and 443 in the OS firewall..."
  for p in 80 443; do
    iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT
  done
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; fi
fi

cat > /etc/caddy/Caddyfile << CADDY
$DOMAIN {
	reverse_proxy 127.0.0.1:8080
}
CADDY

systemctl daemon-reload
systemctl enable --now sixbricks-relay
systemctl restart sixbricks-relay
systemctl enable caddy
systemctl restart caddy

echo "Waiting for the HTTPS certificate (up to 90 seconds)..."
OK=""
for i in $(seq 1 18); do
  if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then OK=1; break; fi
  sleep 5
done

echo
if [ -n "$OK" ]; then
  echo "=================== RELAY IS RUNNING ==================="
else
  echo "Relay installed, but HTTPS isn't answering yet."
  echo "Check ports 80 and 443 are open in the cloud firewall"
  echo "(Oracle: VCN Security List ingress rules; Lightsail: Networking tab), then run:"
  echo "  sudo systemctl restart caddy && curl https://$DOMAIN/health"
  echo "========================================================"
fi
echo
echo "1) Send this IP to Interparcel for the whitelist:"
echo "     $IP"
echo
echo "2) Add these two Script Properties in Google Apps Script:"
echo "     RELAY_URL     https://$DOMAIN/quote"
echo "     RELAY_SECRET  $SECRET"
echo
echo "(To see these again later: sudo cat /etc/sixbricks-relay.env)"
