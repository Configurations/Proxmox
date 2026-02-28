#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT

# Copyright (c) 2021-2024 black beard
# Author: gael beard
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

# ── FIX 1 : openclaw setup avant de créer le service ─────────────────────────
# openclaw setup initialise ~/.openclaw/openclaw.json avec les clés natives
# (gateway.auth.token, compaction, etc.) sans lesquelles le gateway crashe.
# Il doit tourner AVANT le premier démarrage du service.
msg_info "Running openclaw setup (initialise la config native)"
openclaw setup 2>&1 || true
msg_ok "openclaw setup done"

# ── FIX 2 : gateway.bind = 0.0.0.0 pour rendre le dashboard accessible ───────
# Par défaut openclaw écoute sur 127.0.0.1 — inaccessible depuis l'extérieur du LXC.
# On injecte gateway.bind dans le JSON généré par setup.
msg_info "Patching openclaw.json — gateway.bind 0.0.0.0"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
if [ -f "$OPENCLAW_JSON" ]; then
  # Injecter "bind": "0.0.0.0:18789" dans la section gateway existante
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$OPENCLAW_JSON', 'utf8'));
    if (!cfg.gateway) cfg.gateway = {};
    cfg.gateway.bind = '0.0.0.0:18789';
    fs.writeFileSync('$OPENCLAW_JSON', JSON.stringify(cfg, null, 2));
    console.log('gateway.bind patched');
  "
  msg_ok "gateway.bind = 0.0.0.0:18789"
else
  msg_error "openclaw.json introuvable après setup — vérifier manuellement"
fi

# ── FIX 3 : variables d'environnement avec chemin absolu ─────────────────────
# Le service systemd tourne en root mais sans shell interactif — HOME est /root.
# On utilise /root/.openclaw explicitement pour éviter tout problème de résolution.
msg_info "Running openclaw setup"
openclaw setup 2>&1 || true
msg_ok "openclaw setup done"

msg_info "Patching gateway.bind"
node -e "
  const fs = require('fs');
  const p = '/root/.openclaw/openclaw.json';
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  if (!cfg.gateway) cfg.gateway = {};
  cfg.gateway.bind = '0.0.0.0:18789';
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
  console.log('gateway.bind patched');
"
msg_ok "gateway.bind = 0.0.0.0:18789"

msg_info "Setting up environment"
cat >> /etc/environment <<'EOF'
OPENCLAW_HOME=/opt/openclaw
OPENCLAW_STATE_DIR=/opt/openclaw/state
OPENCLAW_CONFIG_PATH=/root/.openclaw/openclaw.json
EOF
msg_ok "Environment configured"

# ── FIX 4 : service systemd avec HOME et config path explicites ───────────────
# Sans Environment=HOME=/root, systemd ne résout pas ~ dans openclaw.json.
# On pointe explicitement vers /root/.openclaw/openclaw.json.
msg_info "Creating systemd service"
OPENCLAW_BIN=$(command -v openclaw)
cat > /etc/systemd/system/openclaw-gateway.service <<EOF
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
ExecStart=${OPENCLAW_BIN} gateway
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start openclaw-gateway
sleep 3
systemctl is-active openclaw-gateway && msg_ok "OpenClaw Gateway service started" || msg_error "Service failed to start — run: journalctl -u openclaw-gateway -n 20"

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
  const fs = require('fs');
  try {
    const cfg = JSON.parse(fs.readFileSync('/root/.openclaw/openclaw.json', 'utf8'));
    console.log(cfg.gateway?.auth?.token || 'voir ~/.openclaw/openclaw.json');
  } catch(e) { console.log('voir ~/.openclaw/openclaw.json'); }
" 2>/dev/null)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ OpenClaw install successful !"
echo ""
echo "  Dashboard : http://${IP}:18789"
echo "  Token     : ${TOKEN}"
echo ""
echo "  Next step — install agents :"
echo "  Available team to work on project mobile application :"
echo "  enter in the container : pct enter ${CTID}"
echo "  bash -c \"\$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/Teams/Project_mobile_application/install-agents.sh)\""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"