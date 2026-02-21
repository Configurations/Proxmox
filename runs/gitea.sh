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
   _______ __
  / ____(_) /____  ____ _
 / / __/ / __/ _ \/ __ `/
/ /_/ / / /_/  __/ /_/ /
\____/_/\__/\___/\__,_/
EOF
}

header_info
APP="gitea"
var_disk="8"
var_cpu="2"
var_ram="1024"
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
  if [[ ! -f /usr/local/bin/gitea ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
  RELEASE=$(curl -s https://api.github.com/repos/go-gitea/gitea/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
  msg_info "Updating Gitea to ${RELEASE}"
  systemctl stop gitea
  wget -qO /usr/local/bin/gitea \
    "https://github.com/go-gitea/gitea/releases/download/${RELEASE}/gitea-${RELEASE#v}-linux-amd64"
  chmod +x /usr/local/bin/gitea
  systemctl start gitea
  msg_ok "Updated Gitea to ${RELEASE}"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
