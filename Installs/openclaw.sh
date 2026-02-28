#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck / black beard
# License: MIT

## Install OpenClaw
## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/openclaw.sh)"

if [[ ! -v FUNCTIONS_FILE_PATH ]]; then
  source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION:-main}/scripts/build.func")
else
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
fi

color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get install -y curl sudo mc ca-certificates gnupg build-essential git
msg_ok "Installed Dependencies"

msg_info "Installing Playwright/Chromium Dependencies"
ALSA_PKG="libasound2"
if apt-cache show libasound2t64 &>/dev/null; then
  ALSA_PKG="libasound2t64"
fi
$STD apt-get install -y \
  libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
  libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
  libgbm1 "$ALSA_PKG" libpango-1.0-0 libcairo2 libxshmfence1 \
  fonts-liberation fonts-noto-color-emoji xvfb
msg_ok "Installed Playwright/Chromium Dependencies"

msg_info "Installing Node.js 22"
$STD bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
$STD apt-get install -y nodejs
msg_ok "Installed Node.js $(node --version)"

msg_info "Installing OpenClaw"
mkdir -p /opt/openclaw/state
$STD npm install -g openclaw
msg_ok "Installed OpenClaw $(openclaw --version 2>/dev/null || echo '')"

# ── Extraire le mot de passe root depuis $PASSWORD (format: "-password xxx") ──
# $PASSWORD est exporté par build_container() depuis build.func.
# On l'écrit dans .secrets pour que install-agents.sh puisse le lire.
msg_info "Storing dashboard credentials"
mkdir -p /root/.openclaw
DASHBOARD_PASSWORD=""
if [[ "$PASSWORD" == -password* ]]; then
  DASHBOARD_PASSWORD="${PASSWORD#-password }"
fi
if [ -z "$DASHBOARD_PASSWORD" ]; then
  # Pas de mot de passe défini (automatic login) — on en génère un
  DASHBOARD_PASSWORD=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 16)
fi
echo "DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}" > /root/.openclaw/.secrets
chmod 600 /root/.openclaw/.secrets
msg_ok "Credentials stored in /root/.openclaw/.secrets"

# ── openclaw setup (initialise openclaw.json avec les clés natives) ───────────
msg_info "Running openclaw setup"
openclaw setup 2>&1 || true
msg_ok "openclaw setup done"

# ── Patch gateway.mode = local + auth password ────────────────────────────────
msg_info "Patching openclaw.json"
DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD" node << 'NODEJS'
const fs  = require('fs');
const p   = '/root/.openclaw/openclaw.json';
const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
const pwd = process.env.DASHBOARD_PASSWORD;
if (!cfg.gateway) cfg.gateway = {};
cfg.gateway.mode = 'local';
cfg.gateway.auth = { mode: 'password', password: pwd };
fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
console.log('gateway patched');
NODEJS
msg_ok "gateway.mode = local, auth = password"

# ── Variables d'environnement ─────────────────────────────────────────────────
msg_info "Setting up environment"
cat >> /etc/environment << 'EOF'
OPENCLAW_HOME=/opt/openclaw
OPENCLAW_STATE_DIR=/opt/openclaw/state
OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
EOF
msg_ok "Environment configured"

# ── Service systemd ───────────────────────────────────────────────────────────
msg_info "Creating systemd service"
cat > /etc/systemd/system/openclaw-gateway.service << 'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
Environment="HOME=/root"
Environment="OPENCLAW_HOME=/opt/openclaw"
Environment="OPENCLAW_STATE_DIR=/opt/openclaw/state"
Environment="OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json"
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway
sleep 3
systemctl is-active openclaw-gateway \
  && msg_ok "OpenClaw Gateway service started" \
  || msg_error "Service failed — run: journalctl -u openclaw-gateway -n 20"

msg_info "Running openclaw doctor"
openclaw doctor 2>&1 || true
msg_ok "Doctor check done"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

IP=$(hostname -I | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ OpenClaw installé avec succès !"
echo ""
echo "  🔒 Dashboard via tunnel SSH (Windows PowerShell) :"
echo "     ssh -L 18789:127.0.0.1:18789 root@${IP} -N"
echo "     Puis : http://127.0.0.1:18789"
echo "     Mot de passe dashboard : ${DASHBOARD_PASSWORD}"
echo ""
echo "  Prochaine étape — installer les agents :"
echo "  bash -c \"\$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/Openclaw/install-agent.sh)\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"