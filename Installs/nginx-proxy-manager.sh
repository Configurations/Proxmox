#!/usr/bin/env bash

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/nginx-proxy-manager.sh)"
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

msg_info "Installing Nginx Proxy Manager"
mkdir -p /opt/nginx-proxy-manager/{data,letsencrypt}
cat > /opt/nginx-proxy-manager/docker-compose.yml <<'EOF'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
docker compose -f /opt/nginx-proxy-manager/docker-compose.yml pull --quiet
msg_ok "Installed Nginx Proxy Manager"

msg_info "Creating Service"
cat > /etc/systemd/system/nginx-proxy-manager.service <<'EOF'
[Unit]
Description=Nginx Proxy Manager
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/nginx-proxy-manager
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
$STD systemctl daemon-reload
$STD systemctl enable --now nginx-proxy-manager
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
echo "  Nginx Proxy Manager installed successfully!"
echo "  Admin UI: http://${IP}:81"
echo ""
echo "  Default credentials:"
echo "    Email:    admin@example.com"
echo "    Password: changeme"
echo ""
echo "  Change them immediately after first login!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
