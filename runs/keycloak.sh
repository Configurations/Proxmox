# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE
#!/usr/bin/env bash
set -xe
trap 'echo "Erreur dans le script"; exit 1' ERR
BUILD_VERSION="main"
export BUILD_VERSION
source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION}/scripts/build.func")

function header_info {
clear
cat <<"EOF"
   __ __           __            __
  / //_/__  __  __/ /____  _____/ /
 / ,< / _ \/ / / / / ___/ / ___/ /
/ /| /  __/ /_/ / / /__  / /  / /
/_/ |_\___/\__, /_/\___/ /_/  /_/
          /____/
EOF
}

header_info
APP="Keycloak"
var_disk="6"
var_cpu="2"
var_ram="2048"
var_os="debian"
var_version="12"
variables
color
catch_errors

function default_settings() {
  CT_TYPE="1"
  PW=""
  CT_ID=$NEXTID
  HN=$NSAPP
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  DISABLEIP6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  echo_default
}

function update_script() {
  header_info
  if [[ ! -d /opt/keycloak ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  RELEASE=$(curl -s https://api.github.com/repos/keycloak/keycloak/releases/latest \
    | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
  msg_info "Updating Keycloak to v${RELEASE}"
  systemctl stop keycloak
  cd /opt
  wget -q "https://github.com/keycloak/keycloak/releases/download/${RELEASE}/keycloak-${RELEASE}.tar.gz"
  tar -xzf "keycloak-${RELEASE}.tar.gz"
  rm -rf keycloak
  mv "keycloak-${RELEASE}" keycloak
  rm -f "keycloak-${RELEASE}.tar.gz"
  systemctl start keycloak
  msg_ok "Updated Keycloak to v${RELEASE}"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
