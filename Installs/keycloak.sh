#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE
## bash -c "$(wget -qLO - https://raw.githubusercontent.com/Configurations/Proxmox/main/Installs/keycloak.sh)"

# if the script is launch alone without the container creation
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
  JAVA_PKG="openjdk17-jre-headless"
else
  install_pkg() { $STD apt-get install -y "$@"; }
  cleanup_pkg() { $STD apt-get -y autoremove; $STD apt-get -y autoclean; }
  JAVA_PKG="ca-certificates-java openjdk-17-jre-headless"
fi

msg_info "Installing Dependencies (Patience)"
install_pkg curl sudo mc $JAVA_PKG
msg_ok "Installed Dependencies"

RELEASE=$(curl -s https://api.github.com/repos/keycloak/keycloak/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
msg_info "Installing Keycloak v$RELEASE"
cd /opt
wget -q https://github.com/keycloak/keycloak/releases/download/$RELEASE/keycloak-$RELEASE.tar.gz
$STD tar -xvf keycloak-$RELEASE.tar.gz
mv keycloak-$RELEASE keycloak
msg_ok "Installed Keycloak"

msg_info "Creating Service"
service_path="/etc/systemd/system/keycloak.service"
echo "[Unit]
Description=Keycloak
After=network-online.target
[Service]
User=root
WorkingDirectory=/opt/keycloak
ExecStart=/opt/keycloak/bin/kc.sh start-dev
[Install]
WantedBy=multi-user.target" >$service_path
$STD systemctl enable --now keycloak.service
msg_ok "Created Service"

systemctl stop keycloak.service
cd /opt/keycloak
ADMIN_PASS=$(openssl rand -base64 16)
bin/kc.sh bootstrap-admin user --bootstrap-admin-username temp-admin --bootstrap-admin-password "$ADMIN_PASS"

# Affichage TRÈS visible du mot de passe
echo ""
echo "=================================================="
echo "⚠️  KEYCLOAK ADMIN CREDENTIALS (WRITE DOWN NOW!)  ⚠️"
echo "=================================================="
echo "Username: temp-admin"
echo "Password: $ADMIN_PASS"
echo "=================================================="
echo ""

systemctl start keycloak.service

motd_ssh
customize

msg_info "Cleaning up"
cleanup_pkg
msg_ok "Cleaned"