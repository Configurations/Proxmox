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
    ____  _       __          __
   / __ \(_)     / /_  ____  / /__
  / /_/ / /_____/ __ \/ __ \/ / _ \
 / ____/ /_____/ / / / /_/ / /  __/
/_/   /_/     /_/ /_/\____/_/\___/
EOF
}

header_info
APP="Pi-hole"
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
  if [[ ! -f /usr/local/bin/pihole ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  msg_info "Updating Pi-hole"
  pihole -up
  msg_ok "Updated Pi-hole"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
