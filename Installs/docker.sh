#!/usr/bin/env bash

# Copyright (c) 2021-2024 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/tteck/Proxmox/raw/main/LICENSE

## Install docker
## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/docker.sh)"

# if the script is launch alone without the container creation
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

get_latest_release() {
  local version=$(curl -sL https://api.github.com/repos/$1/releases/latest 2>/dev/null | grep '"tag_name":' | cut -d'"' -f4)
  if [ -z "$version" ]; then
    msg_error "Failed to retrieve latest version for $1"
    exit 1
  fi
  echo "$version"
}

DOCKER_LATEST_VERSION=$(get_latest_release "moby/moby") || exit 1
PORTAINER_LATEST_VERSION=$(get_latest_release "portainer/portainer") || exit 1
PORTAINER_AGENT_LATEST_VERSION=$(get_latest_release "portainer/agent") || exit 1
DOCKER_COMPOSE_LATEST_VERSION=$(get_latest_release "docker/compose") || exit 1

msg_info "Installing Docker $DOCKER_LATEST_VERSION"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
if command -v apk &>/dev/null; then
  $STD apk add --no-cache docker docker-cli-compose
  $STD rc-update add docker default
  $STD service docker start
else
  $STD sh <(curl -sSL https://get.docker.com)
fi
msg_ok "Installed Docker $DOCKER_LATEST_VERSION"

echo -n "Would you like to add Portainer? <y/N> "
read -r prompt
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  msg_info "Installing Portainer $PORTAINER_LATEST_VERSION"
  docker volume create portainer_data >/dev/null
  $STD docker run -d \
    -p 8000:8000 \
    -p 9443:9443 \
    --name=portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
  msg_ok "Installed Portainer $PORTAINER_LATEST_VERSION"
else
  echo -n "Would you like to add the Portainer Agent? <y/N> "
  read -r prompt
  if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
    msg_info "Installing Portainer agent $PORTAINER_AGENT_LATEST_VERSION"
    $STD docker run -d \
      -p 9001:9001 \
      --name portainer_agent \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v /var/lib/docker/volumes:/var/lib/docker/volumes \
      portainer/agent
    msg_ok "Installed Portainer Agent $PORTAINER_AGENT_LATEST_VERSION"
  fi
fi
echo -n "Would you like to add Docker Compose? <y/N> "
read -r prompt
if [[ ${prompt,,} =~ ^(y|yes)$ ]]; then
  msg_info "Installing Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"
  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p $DOCKER_CONFIG/cli-plugins
  curl -sSL https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_LATEST_VERSION/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose
  chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
  msg_ok "Installed Docker Compose $DOCKER_COMPOSE_LATEST_VERSION"
fi

motd_ssh
customize

msg_info "Cleaning up"
cleanup_pkg
msg_ok "Cleaned"