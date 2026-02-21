#!/usr/bin/env bash

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/vaultwarden.sh)"
## Requires: privileged container (CT_TYPE=0) for Docker support

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
$STD apt-get install -y curl ca-certificates gnupg
msg_ok "Installed Dependencies"

msg_info "Installing Docker"
$STD sh <(curl -sSL https://get.docker.com)
msg_ok "Installed Docker"

msg_info "Installing Vaultwarden"
mkdir -p /opt/vaultwarden/data
cat > /opt/vaultwarden/docker-compose.yml <<'EOF'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - ./data:/data
    environment:
      - WEBSOCKET_ENABLED=true
      - LOG_LEVEL=warn
EOF
docker compose -f /opt/vaultwarden/docker-compose.yml pull --quiet
msg_ok "Installed Vaultwarden"

msg_info "Creating Service"
cat > /etc/systemd/system/vaultwarden.service <<'EOF'
[Unit]
Description=Vaultwarden (Bitwarden-compatible server)
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/vaultwarden
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable --now vaultwarden
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
echo "  Vaultwarden installed successfully!"
echo "  UI:    http://${IP}:8080"
echo "  Admin: http://${IP}:8080/admin"
echo ""
echo "  Note: HTTPS required for Bitwarden clients."
echo "  Use a reverse proxy (Nginx Proxy Manager)"
echo "  or set DOMAIN= in docker-compose.yml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
