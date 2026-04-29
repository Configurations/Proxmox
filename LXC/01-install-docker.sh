#!/bin/bash
###############################################################################
# Script 01 : Installation de Docker dans un Container LXC
#
# A executer DANS le container LXC (en tant que root).
# Adapte pour LXC privileged (pas de sudo, pas de qemu-guest-agent).
#
# Usage depuis l'hote Proxmox :
#   pct exec <CTID> -- bash -c "$(wget -qLO - <URL>)"
#
# Note 1 : ce script installe UNIQUEMENT Docker + outils de base.
# Pas de reverse proxy (Caddy/Nginx) : a deployer separement, soit en service
# Swarm via le routing mesh, soit sur un LXC dedie.
#
# Note 2 : la configuration Docker est compatible Swarm par defaut
# (live-restore: false). Pour Docker classique bare-metal uniquement,
# lancez avec LIVE_RESTORE=1.
#
# Note 3 : le pool d'adresses Docker est fixe a 172.30.0.0/16 (subnets /24)
# pour eviter les conflits avec :
#   - Le pool ingress par defaut de Swarm (10.0.0.0/8)
#   - Le pool overlay choisi pour Swarm (10.20.0.0/16 dans 02-init-swarm.sh)
#   - Les LAN homelab classiques (192.168.x.x, 10.x.x.x)
###############################################################################
set -euo pipefail

# ── Mode non-interactif pour apt/dpkg ─────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# Espace minimum requis dans / avant les operations majeures (en MB)
MIN_FREE_MB="${MIN_FREE_MB:-1024}"

# live-restore : par defaut DESACTIVE (incompatible avec Swarm)
# Mettre LIVE_RESTORE=1 pour Docker classique uniquement
LIVE_RESTORE="${LIVE_RESTORE:-0}"

# Pool d'adresses pour les bridges Docker classiques (docker0, docker_gwbridge,
# custom networks). NE PAS utiliser 172.20.0.0/16 : conflit avec Swarm ingress.
DOCKER_ADDR_POOL="${DOCKER_ADDR_POOL:-172.30.0.0/16}"
DOCKER_ADDR_POOL_SIZE="${DOCKER_ADDR_POOL_SIZE:-24}"

echo "==========================================="
echo "  Installation Docker (LXC)"
echo "==========================================="
echo ""

# ── Verifier qu'on est root ──────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERREUR : Ce script doit etre execute en tant que root."
    echo "         Pas de sudo dans un LXC : connectez-vous en root."
    exit 1
fi

# ── Helper : verifier l'espace disque libre ──────────────────────────────────
check_disk_space() {
    local context="$1"
    local free_mb
    free_mb=$(df --output=avail -BM / | tail -1 | tr -d 'M ')

    if [ "${free_mb}" -lt "${MIN_FREE_MB}" ]; then
        echo ""
        echo "  ERREUR : espace disque insuffisant (${free_mb} MB libre, ${MIN_FREE_MB} MB requis)"
        echo "  Contexte : ${context}"
        echo ""
        echo "  Solutions :"
        echo "  - Liberer : apt clean && rm -rf /tmp/* /var/cache/apt/archives/*.deb"
        echo "  - Etendre rootfs depuis l'hote : pct resize <CTID> rootfs +10G"
        echo "  - Verifier le pool Proxmox : pvesm status"
        exit 1
    fi
    echo "  -> Espace disque libre : ${free_mb} MB (OK)"
}

check_disk_space "demarrage du script"
echo ""

# ── 1. Mise a jour systeme ───────────────────────────────────────────────────
echo "[1/5] Mise a jour du systeme..."
apt-get update -qq
apt-get "${APT_OPTS[@]}" upgrade -y -qq
echo "  -> OK"

# ── 2. Outils de base ───────────────────────────────────────────────────────
echo "[2/5] Installation des outils de base..."
check_disk_space "avant installation des outils de base"
apt-get "${APT_OPTS[@]}" install -y -qq \
  curl wget git vim htop tmux \
  ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv \
  openssh-server \
  unattended-upgrades apt-listchanges
echo "  -> OK"

# ── 3. Mises a jour automatiques (security only) ────────────────────────────
echo "[3/5] Configuration des mises a jour automatiques (securite uniquement)..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    // Docker mis a jour manuellement (cycle dedie, pas via security feed)
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl restart unattended-upgrades >/dev/null 2>&1 || true
echo "  -> Patches de securite Ubuntu actives (Docker exclu)"

# ── 4. Repository Docker + installation ─────────────────────────────────────
echo "[4/5] Installation Docker Engine..."
check_disk_space "avant installation de Docker (besoin ~500 MB)"

install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get "${APT_OPTS[@]}" install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
echo "  -> OK"

# ── 5. Configuration Docker production ──────────────────────────────────────
echo "[5/5] Configuration Docker pour la production..."
mkdir -p /etc/docker

# live-restore : par defaut false (compatible Swarm)
if [ "${LIVE_RESTORE}" = "1" ]; then
    LIVE_RESTORE_VAL="true"
    echo "  -> live-restore : true (Docker classique, NON compatible Swarm)"
else
    LIVE_RESTORE_VAL="false"
    echo "  -> live-restore : false (compatible Swarm)"
fi

echo "  -> Pool d'adresses Docker : ${DOCKER_ADDR_POOL} (subnets /${DOCKER_ADDR_POOL_SIZE})"

tee /etc/docker/daemon.json > /dev/null << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {"base": "${DOCKER_ADDR_POOL}", "size": ${DOCKER_ADDR_POOL_SIZE}}
  ],
  "storage-driver": "overlay2",
  "live-restore": ${LIVE_RESTORE_VAL}
}
EOF

systemctl enable docker >/dev/null 2>&1
systemctl restart docker
echo "  -> OK"

# ── Nettoyage du cache apt ───────────────────────────────────────────────────
echo ""
echo "  Nettoyage du cache apt..."
apt-get clean
apt-get autoremove -y -qq 2>/dev/null || true
echo "  -> OK"

# ── Verification finale ──────────────────────────────────────────────────────
echo ""
echo "  Verification..."
echo ""

if docker info &>/dev/null; then
    echo "  Docker Engine : $(docker --version)"
    echo "  Compose       : $(docker compose version)"
    echo ""
    if docker run --rm hello-world &>/dev/null; then
        echo "  Docker run    : OK"
    else
        echo "  Docker run    : echec (registry inaccessible ?)"
    fi
else
    echo "  ERREUR : Docker ne repond pas."
    echo "  Verifiez : systemctl status docker"
    echo "  Logs     : journalctl -u docker -n 50"
    exit 1
fi

FREE_MB=$(df --output=avail -BM / | tail -1 | tr -d 'M ')
echo ""
echo "  Espace disque libre apres installation : ${FREE_MB} MB"

echo ""
echo "==========================================="
echo "  Docker installe dans le LXC."
echo ""
echo "  Configuration :"
echo "  - live-restore : ${LIVE_RESTORE_VAL} ($([ "${LIVE_RESTORE_VAL}" = "false" ] && echo "compatible Swarm" || echo "Docker classique"))"
echo "  - log rotation : 10 MB par fichier, 3 fichiers max"
echo "  - storage      : overlay2"
echo "  - address pool : ${DOCKER_ADDR_POOL} (subnets /${DOCKER_ADDR_POOL_SIZE})"
echo "  - auto-updates : securite uniquement (Docker exclu)"
echo ""
echo "  Notes :"
echo "  - Aucun reverse proxy installe (par design)."
echo "  - Pour exposer des services HTTP : Caddy/Traefik en service Swarm"
echo "    ou LXC dedie au reverse proxy."
echo "  - Pool 172.30.0.0/16 evite les conflits avec Swarm ingress (10.x)"
echo "    et le pool overlay 10.20.0.0/16 utilise par 02-init-swarm.sh."
echo ""
echo "  Prochaine etape :"
echo "  - Si LXC swarm-ready : ./02-init-swarm.sh <CTID>"
echo "  - Sinon : deployer vos stacks (docker compose up -d)"
echo "==========================================="
