# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE
#!/usr/bin/env bash
set -xe
trap 'echo "Erreur dans le script"; exit 1' ERR
BUILD_VERSION="main"
export BUILD_VERSION
source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION}/scripts/build.func")

function header_info {
clear
cat <<"EOF"
 _    __            ____  __                     __
| |  / /___ ___  __/ / /_/ /      ______ __________/ /__  ____
| | / / __ `/ / / / / __/ / | /| / / __ `/ ___/ __  / _ \/ __ \
| |/ / /_/ / /_/ / / /_/ /| |/ |/ / /_/ / /  / /_/ /  __/ / / /
|___/\__,_/\__,_/_/\__/_/ |__/|__/\__,_/_/   \__,_/\___/_/ /_/
EOF
}

header_info
APP="vaultwarden"
var_disk="4"
var_cpu="1"
var_ram="512"
var_os="debian"
var_version="12"
variables
color
catch_errors

function default_settings() {
  CT_TYPE="0"
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
  if [[ ! -d /opt/vaultwarden ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  msg_info "Updating Vaultwarden"
  cd /opt/vaultwarden
  docker compose pull --quiet
  docker compose up -d
  msg_ok "Updated Vaultwarden"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
