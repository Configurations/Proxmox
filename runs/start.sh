# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE
#!/usr/bin/env bash
set -xe
trap 'echo "Erreur dans le script"; exit 1' ERR
BUILD_VERSION="main"
export BUILD_VERSION
FUNC_FILE=$(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION}/scripts/build.func" 2>/dev/null)
if [ -z "$FUNC_FILE" ]; then
  echo "Erreur : Impossible de charger les fonctions"
  exit 1
fi
source <(echo "$FUNC_FILE")

# --- CLI flags ---
# --update CTID  : trigger /usr/bin/update inside an existing container from the Proxmox host
# --dry-run | -n : show what would be created without actually creating anything
DRY_RUN=0
export DRY_RUN

if [[ "${1:-}" == "--update" && -n "${2:-}" ]]; then
  UPDATE_CTID="$2"
  if ! pct list | awk 'NR>1{print $1}' | grep -qx "$UPDATE_CTID"; then
    echo "Error: container $UPDATE_CTID not found."
    exit 1
  fi
  echo "Triggering update for container $UPDATE_CTID..."
  pct exec "$UPDATE_CTID" -- bash -c "/usr/bin/update"
  echo "Update completed."
  exit 0
fi

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

function header_info {
clear
cat <<"EOF"
Select application!
EOF
}

header_info
# echo -e "Loading..."
APP=$(select_application)
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
  if [ $HN = "empty" ]; then
    HN="NewHost"
  else
    HN=$NSAPP
  fi
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
