#!/usr/bin/env bash

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/uptime-kuma.sh)"

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
$STD apt-get install -y curl ca-certificates gnupg git
msg_ok "Installed Dependencies"

msg_info "Installing Node.js 20"
$STD curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
$STD apt-get install -y nodejs
msg_ok "Installed Node.js $(node --version)"

msg_info "Installing Uptime Kuma"
$STD git clone https://github.com/louislam/uptime-kuma.git /opt/uptime-kuma --depth 1
cd /opt/uptime-kuma
$STD npm run setup
msg_ok "Installed Uptime Kuma"

msg_info "Creating Service"
cat > /etc/systemd/system/uptime-kuma.service <<'EOF'
[Unit]
Description=Uptime Kuma
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/uptime-kuma
ExecStart=/usr/bin/node server/server.js
Restart=on-failure
RestartSec=5s
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable --now uptime-kuma
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Uptime Kuma installed successfully!"
echo "  UI: http://${IP}:3001"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
