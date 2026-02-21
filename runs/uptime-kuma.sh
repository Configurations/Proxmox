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
  __  __      __  _               __ __
 / / / /___  / /_(_)___ ___  ___ / //_/  ______ ___  ____ _
/ / / / __ \/ __/ / __ `__ \/ _ / ,<  / / / __ `__ \/ __ `/
/ /_/ / /_/ / /_/ / / / / / /  __/ /| |/ /_/ / / / / / /_/ /
\____/ .___/\__/_/_/ /_/ /_/\___/_/ |_|\__,_/_/ /_/ /_/\__,_/
    /_/
EOF
}

header_info
APP="uptime-kuma"
var_disk="4"
var_cpu="1"
var_ram="512"
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
  if [[ ! -d /opt/uptime-kuma ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  msg_info "Updating Uptime Kuma"
  systemctl stop uptime-kuma
  cd /opt/uptime-kuma
  git pull --quiet
  npm run setup --quiet
  systemctl start uptime-kuma
  msg_ok "Updated Uptime Kuma"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
