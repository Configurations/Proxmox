#!/usr/bin/env bash

# Copyright (c) 2021-2024 black beard
# Author: gael beard
# License: MIT
# https://github.com/Configurations/Proxmox/blob/main/LICENSE

## [REQUIRED] Mettre à jour le nom de l'application et l'URL
## bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/myapp.sh)"

# =============================================================================
# VARIABLES DISPONIBLES (injectées par le script runs/ parent)
# =============================================================================
# $APPLICATION        : Nom complet affiché (ex: "Docker")
# $app                : Nom en minuscules (ex: "docker")
# $FUNCTIONS_FILE_PATH: Contenu de build.func passé par le parent
# $STD                : "" (verbose) ou "silent" (silencieux, via -v)
# $PASSWORD           : Mot de passe root (peut être vide)
# $SSH_ROOT           : "yes" | "no"
# $DISABLEIPV6        : "yes" | "no"
# $VERBOSE            : "yes" | "no"
# =============================================================================

# [REQUIRED] Chargement des fonctions
# Supporte le lancement standalone (sans runs/) et le flux parent
if [[ ! -v FUNCTIONS_FILE_PATH ]]; then
  source <(curl -s "https://raw.githubusercontent.com/Configurations/Proxmox/${BUILD_VERSION:-main}/scripts/build.func")
else
  source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
fi

# [REQUIRED] Initialisation
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# [OPTIONAL] Détection du gestionnaire de paquets (Alpine vs Debian/Ubuntu)
# Utiliser install_pkg / cleanup_pkg dans la suite du script
if command -v apk &>/dev/null; then
  install_pkg() { $STD apk add --no-cache "$@"; }
  cleanup_pkg() { $STD apk cache clean; }
else
  install_pkg() { $STD apt-get install -y "$@"; }
  cleanup_pkg() { $STD apt-get -y autoremove; $STD apt-get -y autoclean; }
fi

# [REQUIRED] Dépendances communes
msg_info "Installing Dependencies"
install_pkg curl sudo mc
msg_ok "Installed Dependencies"

# =============================================================================
# INSTALLATION DE L'APPLICATION
# =============================================================================

# msg_info "Installing MyApp vX.Y.Z"
# ...commandes d'installation...
# msg_ok "Installed MyApp vX.Y.Z"

# =============================================================================
# [OPTIONAL] SERVICE SYSTEMD
# =============================================================================

# msg_info "Creating Service"
# cat > /etc/systemd/system/myapp.service <<'EOF'
# [Unit]
# Description=MyApp
# After=network.target
#
# [Service]
# Type=simple
# User=root
# ExecStart=/usr/bin/myapp
# Restart=on-failure
# RestartSec=5s
#
# [Install]
# WantedBy=multi-user.target
# EOF
# $STD systemctl daemon-reload
# $STD systemctl enable --now myapp
# msg_ok "Created Service"

# =============================================================================
# [REQUIRED] FINALISATION
# =============================================================================

motd_ssh
customize

msg_info "Cleaning up"
cleanup_pkg
msg_ok "Cleaned"
