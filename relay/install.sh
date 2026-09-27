#!/usr/bin/env bash
# Six Bricks — Interparcel relay installer.
# Works on Ubuntu/Debian (apt) and Oracle Linux / RHEL-family (dnf), x86_64 or ARM.
# Safe on an existing server: never replaces an existing Node.js, never takes over
# ports 80/443 if something else is using them, and keeps any existing Caddy sites.
#
#   curl -fsSL https://raw.githubusercontent.com/robbiebaskin/sixbricks/main/relay/install.sh | sudo bash
# Optional own domain (A record -> this server's IP):
#   curl -fsSL .../install.sh | sudo DOMAIN=relay.example.com.au bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }

REPO_RAW="https://raw.githubusercontent.com/robbiebaskin/sixbricks/main/relay"
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf >/dev/null 2>&1; then PKG=dnf
else echo "Unsupported system: needs apt-get or dnf."; exit 1; fi

CADDY_PREEXISTING=""; command -v caddy >/dev/null 2>&1 && CADDY_PREEXISTING=1
BUSY="$(ss -ltnpH 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -v caddy || true)"
if [ -n "$BUSY" ]; then
  echo "Another program is already using port 80 or 443 on this server:"
  echo "$BUSY"
  echo "Stopping here so it isn't disrupted. Share this output and the setup can be adapted."
  exit 1
fi

IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
DOMAIN="${DOMAIN:-${IP//./-}.sslip.io}"
echo "== Six Bricks relay installer =="
echo "System:        $PKG ($(uname -m))"
echo "Public IP:     $IP"
echo "Relay address: https://$DOMAIN"
echo
read -rsp "Paste your Interparcel API key and press Enter (input is hidden): " APIKEY < /dev/tty
echo
[ -n "$APIKEY" ] || { echo "No API key entered - aborting."; exit 1; }

# ---------- Node.js (only installed if missing; an existing one is never changed) ----------
if command -v node >/dev/null 2>&1; then
  echo "Using existing Node.js $(node -v)"
else
  echo "Installing Node.js..."
  if [ "$PKG" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q && apt-get install -y -q nodejs
  else
    dnf -y -q module enable nodejs:20 2>/dev/null || dnf -y -q module enable nodejs:22 2>/dev/null || true
    dnf -y -q install nodejs
  fi
fi
NODE_BIN="$(command -v node)"
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || { echo "Node 18+ required, found $("$NODE_BIN" -v). Not changing it - aborting."; exit 1; }

# ---------- Caddy (HTTPS front door) ----------
if [ -z "$CADDY_PREEXISTING" ]; then
  echo "Installing Caddy..."
  if [ "$PKG" = apt ] && apt-get install -y -q caddy; then
    :
  else
    case "$(uname -m)" in
      aarch64|arm64) CA=arm64 ;;
      x86_64|amd64)  CA=amd64 ;;
      *) echo "Unsupported CPU $(uname -m)"; exit 1 ;;
    esac
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$CA" -o /usr/local/bin/caddy
    chmod 755 /usr/local/bin/caddy
    command -v restorecon >/dev/null 2>&1 && restorecon /usr/local/bin/caddy || true
    getent group caddy >/dev/null || groupadd --system caddy
    id caddy &>/dev/null || useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
    mkdir -p /etc/caddy
    cat > /etc/systemd/system/caddy.service << 'UNIT'
[Unit]
Description=Caddy web server
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  fi
fi
CADDY_BIN="$(command -v caddy || echo /usr/local/bin/caddy)"

# ---------- Relay ----------
echo "Installing relay..."
id sixbricks &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin sixbricks
mkdir -p /opt/sixbricks-relay
curl -fsSL "$REPO_RAW/relay.js" -o /opt/sixbricks-relay/relay.js
chmod 644 /opt/sixbricks-relay/relay.js
command -v restorecon >/dev/null 2>&1 && restorecon -R /opt/sixbricks-relay || true

if [ -f /etc/sixbricks-relay.env ] && grep -q '^RELAY_SECRET=' /etc/sixbricks-relay.env; then
  SECRET="$(grep '^RELAY_SECRET=' /etc/sixbricks-relay.env | cut -d= -f2-)"   # keep existing secret on re-run
else
  SECRET="$(openssl rand -hex 32)"
fi
( umask 077; printf 'INTERPARCEL_API_KEY=%s\nRELAY_SECRET=%s\n' "$APIKEY" "$SECRET" > /etc/sixbricks-relay.env )

cat > /etc/systemd/system/sixbricks-relay.service << UNIT
[Unit]
Description=Six Bricks Interparcel relay
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sixbricks-relay.env
ExecStart=$NODE_BIN /opt/sixbricks-relay/relay.js
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

# ---------- OS firewall ----------
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "Opening ports 80 and 443 in firewalld..."
  firewall-cmd -q --permanent --add-service=http --add-service=https
  firewall-cmd -q --reload
elif iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
  echo "Opening ports 80 and 443 in iptables..."
  for p in 80 443; do
    iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT
  done
  if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; fi
fi

# ---------- Caddy site ----------
SITE_BLOCK="# sixbricks-relay
$DOMAIN {
	reverse_proxy 127.0.0.1:8080
}"
if [ -n "$CADDY_PREEXISTING" ] && [ -f /etc/caddy/Caddyfile ]; then
  if ! grep -q "sixbricks-relay" /etc/caddy/Caddyfile; then
    cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
    printf '\n%s\n' "$SITE_BLOCK" >> /etc/caddy/Caddyfile   # keep existing sites
  fi
else
  printf '%s\n' "$SITE_BLOCK" > /etc/caddy/Caddyfile
fi
"$CADDY_BIN" validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || { echo "Caddy config invalid - check /etc/caddy/Caddyfile"; exit 1; }

systemctl daemon-reload
systemctl enable --now sixbricks-relay
systemctl restart sixbricks-relay
systemctl enable caddy
if [ -n "$CADDY_PREEXISTING" ]; then systemctl reload caddy; else systemctl restart caddy; fi

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
