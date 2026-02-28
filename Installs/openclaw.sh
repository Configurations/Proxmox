#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck / black beard 10:27 PM GMT+01:00 02/28/2026
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

# ── FIX 1 : openclaw setup AVANT le service ───────────────────────────────────
# Initialise ~/.openclaw/openclaw.json avec gateway.auth.token et les clés
# natives. Sans cette étape, le service crashe avec "Missing config".
msg_info "Running openclaw setup (initialise la config native)"
openclaw setup 2>&1 || true
msg_ok "openclaw setup done"

# ── FIX 2 : gateway.mode = local (loopback) ───────────────────────────────────
# OpenClaw refuse de démarrer sans gateway.mode explicite.
# On reste sur loopback (127.0.0.1) — accès via tunnel SSH depuis Windows.
# bind: "lan" ou "0.0.0.0" déclenche une erreur controlUi.allowedOrigins.
msg_info "Patching openclaw.json — gateway.mode = local"
node -e "
  const fs = require('fs');
  const p = '/root/.openclaw/openclaw.json';
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (!cfg.gateway) cfg.gateway = {};
  cfg.gateway.mode = 'local';
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
  console.log('gateway.mode patched');
"
msg_ok "gateway.mode = local (loopback — accès via tunnel SSH)"

# ── FIX 3 : variables d'environnement avec chemin absolu /root ────────────────
msg_info "Setting up environment"
cat >> /etc/environment <<'EOF'
OPENCLAW_HOME=/opt/openclaw
OPENCLAW_STATE_DIR=/opt/openclaw/state
OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
EOF
msg_ok "Environment configured"

# ── FIX 4 : service systemd avec HOME=/root et systemctl enable ───────────────
# HOME requis pour que systemd résolve les chemins ~/.openclaw correctement.
# systemctl enable pour redémarrage automatique après reboot.
# On supprime le "systemctl status" qui retourne exit code 1 et plante le script.
msg_info "Creating systemd service"
cat > /etc/systemd/system/openclaw-gateway.service <<'EOF'
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
TOKEN=$(node -e "
  try {
    const cfg = JSON.parse(require('fs').readFileSync('/root/.openclaw/openclaw.json','utf8'));
    console.log(cfg.gateway && cfg.gateway.auth && cfg.gateway.auth.token ? cfg.gateway.auth.token : 'voir openclaw.json');
  } catch(e) { console.log('voir openclaw.json'); }
" 2>/dev/null)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ OpenClaw installé avec succès !"
echo ""
echo "  🔒 Dashboard accessible via tunnel SSH uniquement (loopback)"
echo ""
echo "  Depuis Windows (PowerShell) :"
echo "  ssh -L 18789:127.0.0.1:18789 root@${IP} -N"
echo ""
echo "  Puis dans le navigateur : http://127.0.0.1:18789"
echo "  Token     : ${TOKEN}"
echo ""
echo "  Prochaine étape — installer les agents :"
echo "  bash -c \"\$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/Teams/Project_mobile_application/install-agents.sh)\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"