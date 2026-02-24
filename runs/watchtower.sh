#!/usr/bin/env bash
# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE
set -xe
trap 'echo "Error in script"; exit 1' ERR
BUILD_VERSION="main"
export BUILD_VERSION
source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION}/scripts/build.func")

function header_info {
clear
cat <<"BANNER"
 __    __    _       _     _
/ / /\ \ \  /_\ __ _| |_ ___| |__| |_ _____      _____ _ __
\ \/  \/ / //_\/ _' | __/ __| '_ \ __/ _ \ \ /\ / / _ \ '__|
 \  /\  / /  _  \ (_| | || (__| | | | || (_) \ V  V /  __/ |
  \/  \/ \_/ \_/\_\__,_|\__\___|_| |_|\__\___/ \_/\_/ \___|_|
BANNER
}

header_info
APP="Watchtower"
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
if ! docker ps -a --filter "name=watchtower" | grep -q watchtower; then
  msg_error "No Watchtower installation found!"
  exit
fi
msg_info "Updating Watchtower"
docker pull containrrr/watchtower:latest
docker restart watchtower
msg_ok "Updated Watchtower"
exit
}

start
build_container
description

msg_ok "Completed Successfully!"
