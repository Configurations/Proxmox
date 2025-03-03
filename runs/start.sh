# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE
#!/usr/bin/env bash
set -xe
trap 'echo "Erreur dans le script"; exit 1' ERR
source <(curl -s https://raw.githubusercontent.com/Configurations/Proxmox/main/scripts/build.func)

function header_info {
clear
echo "install"
}



local -a MENU
#  while read -r line; do
#    local TAG=$(echo $line | awk '{print $1}')
#    local TYPE=$(echo $line | awk '{printf "%-10s", $2}')
#    local FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
#    local ITEM="  Type: $TYPE Free: $FREE "
#    local OFFSET=2
#    if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
#      local MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
""    fi
    MENU+=("$TAG" "ITEM1" "OFF")
    MENU+=("$TAG" "ITEM2" "OFF")
    MENU+=("$TAG" "ITEM3" "OFF")

#  done < <(pvesm status -content $CONTENT | awk 'NR>1')


QUESTION = "Proxmox Scripts" --title "Storage Pools" --radiolist \
      "Which storage pool make a selection, use the Spacebar.\n"

if [ $((${#MENU[@]}/3)) -eq 1 ]; then
    printf ${MENU[0]}
  else
    local STORAGE
    while [ -z "${STORAGE:+x}" ]; do
      STORAGE=$(whiptail --backtitle QUESTION \
      16 $(($MSG_MAX_LENGTH + 23)) 6 \
      "${MENU[@]}" 3>&1 1>&2 2>&3) || exit "Menu aborted."
    done
    printf $STORAGE
  fi



header_info
# echo -e "Loading..."
APP="Docker"
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