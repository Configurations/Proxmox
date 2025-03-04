# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE
#!/usr/bin/env bash
# set -xe
trap 'echo "Erreur dans le script"; exit 1' ERR
source <(curl -s https://raw.githubusercontent.com/Configurations/Proxmox/main/scripts/build.func)

function header_info {
clear
echo "install"
}

function select_application() {
  local -a MENU
  MENUAPPLY=$(curl -s https://raw.githubusercontent.com/Configurations/Proxmox/main/applications.txt)
  IFS=$';' read -r -d '' -a MENU_ARRAY <<< "$MENUAPPLY"
  for item in "${MENU_ARRAY[@]}"; do
    echo "$item"
    MENU+=("$item" "     "  "OFF")
  done
  CHOIX=$(whiptail --title "Menu" --radiolist \
   "Select an application :" 15 50 6 \
   "${MENU[@]}" 3>&1 1>&2 2>&3)
  if [ $? -eq 0 ]; then
    CHOIX=${CHOIX//_/}
    APP=$CHOIX
  fi
}

select_application
header_info
# echo -e "Loading..."
#APP="Docker"
var_disk="4"
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
if [[ ! -d /var ]]; then msg_error "No ${APP} Installation Found!"; exit; fi
msg_info "Updating ${APP} LXC"
apt-get update &>/dev/null
apt-get -y upgrade &>/dev/null
msg_ok "Updated ${APP} LXC"
exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"