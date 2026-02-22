#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## Install OpenClaw
## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/openclaw.sh)"

# if the script is launched alone without the container creation
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
$STD apt-get install -y curl
$STD apt-get install -y sudo
$STD apt-get install -y mc
$STD apt-get install -y ca-certificates
$STD apt-get install -y gnupg
$STD apt-get install -y build-essential
$STD apt-get install -y git
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

msg_info "Setting up environment"
cat >> /etc/environment <<'EOF'
OPENCLAW_HOME=/opt/openclaw
OPENCLAW_STATE_DIR=/opt/openclaw/state
OPENCLAW_CONFIG_PATH=/opt/openclaw/config.json
EOF
msg_ok "Environment configured"

msg_info "Creating systemd service"
cat > /etc/systemd/system/openclaw-gateway.service <<'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
Environment="OPENCLAW_HOME=/opt/openclaw"
Environment="OPENCLAW_STATE_DIR=/opt/openclaw/state"
Environment="OPENCLAW_CONFIG_PATH=/opt/openclaw/config.json"
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable openclaw-gateway
msg_ok "Created OpenClaw Gateway service"

msg_info "Running openclaw doctor"
openclaw doctor 2>&1 || true
msg_ok "Doctor check done"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ OpenClaw installé avec succès !"
echo ""
echo "  ⚠️  ACTION MANUELLE REQUISE (une seule fois) :"
echo "     openclaw onboard --install-daemon"
echo ""
echo "  Le wizard configure :"
echo "    - Clé API (Anthropic / OpenAI)"
echo "    - Canaux (Telegram, Discord...)"
echo ""
echo "  Puis démarrer le service :"
echo "     systemctl start openclaw-gateway"
echo ""
echo "  Dashboard : http://$(hostname -I | awk '{print $1}'):18789"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

