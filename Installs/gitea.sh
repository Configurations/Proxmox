#!/usr/bin/env bash

# Copyright (c) 2021-2026 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/gitea.sh)"

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

if command -v apk &>/dev/null; then
  install_pkg() { $STD apk add --no-cache "$@"; }
  cleanup_pkg() { $STD apk cache clean; }
else
  install_pkg() { $STD apt-get install -y "$@"; }
  cleanup_pkg() { $STD apt-get -y autoremove; $STD apt-get -y autoclean; }
fi

msg_info "Installing Dependencies"
install_pkg curl wget git ca-certificates
msg_ok "Installed Dependencies"

msg_info "Creating git user"
useradd -r -m -d /opt/gitea -s /bin/bash git 2>/dev/null || true
msg_ok "Created git user"

RELEASE=$(curl -s https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
msg_info "Installing Gitea ${RELEASE}"
wget -qO /usr/local/bin/gitea \
  "https://github.com/go-gitea/gitea/releases/download/${RELEASE}/gitea-${RELEASE#v}-linux-amd64"
chmod +x /usr/local/bin/gitea
mkdir -p /opt/gitea/{custom,data,log}
chown -R git:git /opt/gitea
msg_ok "Installed Gitea ${RELEASE}"

msg_info "Creating Service"
cat > /etc/systemd/system/gitea.service <<'EOF'
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
Type=simple
User=git
WorkingDirectory=/opt/gitea
ExecStart=/usr/local/bin/gitea web --config /opt/gitea/custom/conf/app.ini
Restart=on-failure
RestartSec=5s
Environment=HOME=/opt/gitea USER=git GITEA_WORK_DIR=/opt/gitea

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable --now gitea
msg_ok "Created Service"

motd_ssh
customize

msg_info "Cleaning up"
cleanup_pkg
msg_ok "Cleaned"

IP=$(hostname -I | awk '{print $1}')
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Gitea installed successfully!"
echo "  Complete initial setup at: http://${IP}:3000"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
