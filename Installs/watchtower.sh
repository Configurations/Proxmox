#!/usr/bin/env bash

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## Install Watchtower -- automatic Docker container updater
## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/watchtower.sh)"

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
else
  install_pkg() { $STD apt-get install -y "$@"; }
  cleanup_pkg() { $STD apt-get -y autoremove; $STD apt-get -y autoclean; }
fi

msg_info "Installing Dependencies"
install_pkg curl sudo mc
msg_ok "Installed Dependencies"

# Check Docker is available
if ! command -v docker &>/dev/null; then
  msg_info "Installing Docker"
  $STD sh <(curl -sSL https://get.docker.com)
  msg_ok "Installed Docker"
fi

# Retrieve latest Watchtower version
get_latest_release() {
  local version=$(curl -sL https://api.github.com/repos/$1/releases/latest 2>/dev/null | grep '"tag_name":' | cut -d'"' -f4)
  if [ -z "$version" ]; then
    msg_error "Failed to retrieve latest version for $1"
    exit 1
  fi
  echo "$version"
}

WATCHTOWER_VERSION=$(get_latest_release "containrrr/watchtower") || exit 1

msg_info "Installing Watchtower $WATCHTOWER_VERSION"

# Ask which containers to monitor
echo ""
echo -n "Monitor ALL containers? (recommended) <Y/n> "
read -r prompt
if [[ ${prompt,,} =~ ^(n|no)$ ]]; then
  echo -n "Enter container names to monitor (space-separated, e.g: shellia nginx): "
  read -r CONTAINERS
else
  CONTAINERS=""
fi

# Ask for check interval
echo -n "Check interval in seconds? [300]: "
read -r INTERVAL
INTERVAL=${INTERVAL:-300}

# Pull and run Watchtower
docker pull containrrr/watchtower:latest >/dev/null 2>&1

if [ -z "$CONTAINERS" ]; then
  $STD docker run -d \
    --name watchtower \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e WATCHTOWER_CLEANUP=true \
    -e WATCHTOWER_POLL_INTERVAL=$INTERVAL \
    -e WATCHTOWER_NOTIFICATIONS_LEVEL=info \
    containrrr/watchtower:latest
else
  $STD docker run -d \
    --name watchtower \
    --restart unless-stopped \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e WATCHTOWER_CLEANUP=true \
    -e WATCHTOWER_POLL_INTERVAL=$INTERVAL \
    -e WATCHTOWER_NOTIFICATIONS_LEVEL=info \
    containrrr/watchtower:latest $CONTAINERS
fi

msg_ok "Installed Watchtower $WATCHTOWER_VERSION"

docker ps --filter "name=watchtower" --format "  Container: {{.Names}} | Status: {{.Status}}"
echo "  Interval : ${INTERVAL}s"
if [ -z "$CONTAINERS" ]; then
  echo "  Watching : ALL containers"
else
  echo "  Watching : $CONTAINERS"
fi

motd_ssh
customize

msg_info "Cleaning up"
cleanup_pkg
msg_ok "Cleaned"
