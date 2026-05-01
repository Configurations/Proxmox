#!/bin/bash
###############################################################################
# Script unifie : create-lxc.sh
#
# A executer sur l'HOTE PROXMOX (pas dans le container).
#
# Cree (ou reconfigure) un LXC Proxmox, et optionnellement :
#   - installe Docker dans le LXC                    (--docker)
#   - prepare le LXC en "swarm-ready"                (--swarm)
#   - initialise un nouveau cluster Docker Swarm     (--init-swarm)
#   - rejoint un cluster Swarm existant              (--join-swarm)
#
# Flags :
#   --docker                  Installe Docker + permissions LXC Docker
#   --swarm                   Prepare LXC swarm-ready (modules kernel hote,
#                             /dev/net/tun, sysctl reseau, tag swarm-ready)
#   --init-swarm              Init un nouveau cluster Swarm
#                             (implique --docker + --swarm)
#   --join-swarm              Rejoint un cluster Swarm existant
#                             (implique --docker + --swarm)
#       --manager-ip <IP>     IP du manager (obligatoire avec --join-swarm)
#       --token <TOKEN>       Token de join (obligatoire avec --join-swarm)
#       --as-manager          Rejoindre comme manager (defaut : worker)
#
# --init-swarm et --join-swarm sont mutuellement exclusifs.
# Sans aucun flag : LXC nu, aucune optimisation Docker/Swarm.
#
# Usage :
#   ./create-lxc.sh <CTID> [hostname] [flags...]
#
# Exemples :
#   ./create-lxc.sh 200 ag-test
#   ./create-lxc.sh 201 ag-docker --docker
#   ./create-lxc.sh 202 ag-mgr --init-swarm
#   ./create-lxc.sh 203 ag-worker --join-swarm --manager-ip 192.168.10.115 \
#                                 --token SWMTKN-1-xxx
#   STORAGE=extended-lvm DISK_SIZE=50 ./create-lxc.sh 204 ag-data --init-swarm
#
# Variables d'environnement :
#   STORAGE=auto          Selection auto du storage (defaut)
#   DISK_SIZE=30          Taille rootfs en GB
#   CORES=4               Nombre de coeurs
#   MEMORY=8192           RAM en MB
#   SWAP=1024             Swap en MB
#   BRIDGE=vmbr0          Bridge reseau
#   SAFETY_MARGIN_GB=5    Marge libre minimale dans le pool
#   SSH_KEY_DIR=...       Dossier des clefs SSH (defaut /root/.ssh/lxc-keys)
#   LIVE_RESTORE=0        Docker live-restore (0=false, compatible Swarm)
#   DOCKER_ADDR_POOL=172.30.0.0/16   Pool d'IPs des bridges Docker
#   DOCKER_ADDR_POOL_SIZE=24         Masque des subnets Docker
#   POOL_OVERLAY=10.20.0.0/16        Pool overlay Swarm (init-swarm)
#   POOL_MASK=24                     Masque overlay
#   NODE_LABELS="role=control,tenant=agflow"  Labels du node (init-swarm)
#   ADVERTISE_ADDR=<ip>              Force IP advertise Swarm
#   FORCE=1                          Reinit Swarm meme si actif (DESTRUCTIF)
#   FORCE_LEAVE=yes                  Quitte le Swarm courant avant de rejoindre
#   AUTO_FIX=1                       Correction auto live-restore
#   TOKEN_DIR=...                    Dossier des tokens Swarm
#   MIN_FREE_MB=1024                 Espace min dans le LXC (Docker)
#
# Pre-requis (creation) : un template Ubuntu dans le storage local.
#   pveam update
#   pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
###############################################################################
set -uo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Helpers JSON (utilises a la fin pour la sortie unifiee)
# ══════════════════════════════════════════════════════════════════════════════
json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
json_str_or_null() {
    if [ -z "${1:-}" ]; then
        printf 'null'
    else
        printf '"%s"' "$(json_escape "$1")"
    fi
}

fail() {
    echo ""
    echo "  ECHEC : $1"
    [ -n "${2:-}" ] && echo "${2}" | sed 's/^/    /'
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Configuration par defaut
# ══════════════════════════════════════════════════════════════════════════════
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]:-}" != "bash" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi

CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
SWAP="${SWAP:-1024}"
DISK_SIZE="${DISK_SIZE:-30}"
STORAGE="${STORAGE:-auto}"
BRIDGE="${BRIDGE:-vmbr0}"
SSH_KEY_DIR="${SSH_KEY_DIR:-/root/.ssh/lxc-keys}"
SAFETY_MARGIN_GB="${SAFETY_MARGIN_GB:-5}"

# Docker
LIVE_RESTORE="${LIVE_RESTORE:-0}"
DOCKER_ADDR_POOL="${DOCKER_ADDR_POOL:-172.30.0.0/16}"
DOCKER_ADDR_POOL_SIZE="${DOCKER_ADDR_POOL_SIZE:-24}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"

# Swarm init
POOL_OVERLAY="${POOL_OVERLAY:-10.20.0.0/16}"
POOL_MASK="${POOL_MASK:-24}"
DEFAULT_LABELS="role=control,tenant=agflow"
NODE_LABELS="${NODE_LABELS:-${DEFAULT_LABELS}}"
TOKEN_DIR="${TOKEN_DIR:-/root/.ssh/lxc-keys}"
FORCE="${FORCE:-0}"
AUTO_FIX="${AUTO_FIX:-1}"

# Swarm join
LISTEN_ADDR_JOIN="${LISTEN_ADDR:-0.0.0.0:2377}"
FORCE_LEAVE="${FORCE_LEAVE:-no}"

# Etat capture (pour JSON final)
CONF_BACKUP_PATH=""
DOCKER_HELLO_OK=0
DOCKER_INSTALL_OK=0
DOCKER_OK=0
SWARM_READY="false"
TUN_OK="no"
LIVE_RESTORE_FIXED=0
LIVE_RESTORE_ON="no"
SWARM_PRE_STATE="inactive"
KERNEL_MODULES_LOADED=0
NODE_ID=""
WORKER_TOKEN=""
MANAGER_TOKEN=""
TOKEN_FILE=""
JOIN_NEW_STATE=""
JOIN_NEW_ROLE=""
JOIN_NODE_ID=""
ADVERTISE_ADDR_USED=""

# ══════════════════════════════════════════════════════════════════════════════
# Parsing des arguments
# ══════════════════════════════════════════════════════════════════════════════
DOCKER_MODE=0
SWARM_MODE=0
INIT_SWARM=0
JOIN_SWARM=0
JOIN_AS_MANAGER=0
JOIN_MANAGER_IP=""
JOIN_TOKEN=""
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --docker)       DOCKER_MODE=1 ;;
        --swarm)        SWARM_MODE=1 ;;
        --init-swarm)   INIT_SWARM=1 ;;
        --join-swarm)   JOIN_SWARM=1 ;;
        --as-manager)   JOIN_AS_MANAGER=1 ;;
        --manager-ip)   JOIN_MANAGER_IP="${2:-}"; shift ;;
        --token)        JOIN_TOKEN="${2:-}"; shift ;;
        *)              ARGS+=("$1") ;;
    esac
    shift
done
set -- "${ARGS[@]}"

# Implications : --init-swarm et --join-swarm impliquent --docker + --swarm
if [ "${INIT_SWARM}" -eq 1 ] || [ "${JOIN_SWARM}" -eq 1 ]; then
    DOCKER_MODE=1
    SWARM_MODE=1
fi

# Mutuellement exclusifs
if [ "${INIT_SWARM}" -eq 1 ] && [ "${JOIN_SWARM}" -eq 1 ]; then
    fail "--init-swarm et --join-swarm sont mutuellement exclusifs"
fi

# Validation des arguments de --join-swarm
if [ "${JOIN_SWARM}" -eq 1 ]; then
    if [ -z "${JOIN_MANAGER_IP}" ] || [ -z "${JOIN_TOKEN}" ]; then
        fail "--join-swarm requiert --manager-ip <IP> et --token <TOKEN>"
    fi
fi

CTID="${1:-}"
CT_NAME_RAW="${2:-agflow-docker}"
CT_NAME=$(echo "${CT_NAME_RAW}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

if [ -z "${CTID}" ]; then
    cat << 'USAGE'
Usage : ./create-lxc.sh <CTID> [hostname] [flags...]

Flags :
  --docker                  Installe Docker dans le LXC + perms LXC Docker
  --swarm                   Prepare le LXC swarm-ready
  --init-swarm              Init un cluster Swarm (implique --docker + --swarm)
  --join-swarm              Rejoint un cluster (implique --docker + --swarm)
      --manager-ip <IP>     IP du manager (obligatoire avec --join-swarm)
      --token <TOKEN>       Token de join (obligatoire avec --join-swarm)
      --as-manager          Rejoindre comme manager (defaut : worker)

Sans flag : LXC nu (pas de Docker, pas de Swarm).

Containers existants :
USAGE
    pct list 2>/dev/null || true
    exit 1
fi

CONF="/etc/pve/lxc/${CTID}.conf"

# ══════════════════════════════════════════════════════════════════════════════
# TABLEAU DE BORD STORAGES + SELECTION AUTOMATIQUE
# ══════════════════════════════════════════════════════════════════════════════
show_storage_dashboard() {
    echo "==========================================="
    echo "  Etat des storages Proxmox"
    echo "==========================================="
    echo ""
    printf "  %-20s %10s %10s %10s %6s  %s\n" "STORAGE" "TOTAL" "USED" "FREE" "USE%" "STATUS"
    echo "  ------------------------------------------------------------------------"

    pvesm status 2>/dev/null | tail -n +2 | while read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local total_kb=$(echo "$line" | awk '{print $4}')
        local used_kb=$(echo "$line" | awk '{print $5}')
        local avail_kb=$(echo "$line" | awk '{print $6}')

        local total_gb=$((total_kb / 1024 / 1024))
        local used_gb=$((used_kb / 1024 / 1024))
        local avail_gb=$((avail_kb / 1024 / 1024))

        local pct=0
        if [ "$total_kb" -gt 0 ]; then
            pct=$((used_kb * 100 / total_kb))
        fi

        local content
        content=$(grep -A 5 "^${type}: ${name}$" /etc/pve/storage.cfg 2>/dev/null | grep -m1 "content " | awk '{$1=""; print $0}' | xargs || echo "")
        local supports_rootfs="no"
        if [ "${type}" = "lvmthin" ] || [ "${type}" = "zfspool" ]; then
            supports_rootfs="yes"
        elif [ "${type}" = "lvm" ] && echo "${content}" | grep -q "rootdir"; then
            supports_rootfs="yes"
        elif [ "${type}" = "dir" ] && echo "${content}" | grep -q "rootdir"; then
            supports_rootfs="yes"
        fi

        local marker=""
        if [ "${supports_rootfs}" = "no" ]; then
            marker="(no rootfs)"
        elif [ "${pct}" -ge 90 ]; then
            marker="[!] SATURE"
        elif [ "${pct}" -ge 75 ]; then
            marker="[~] CHARGE"
        elif [ "${status}" != "active" ]; then
            marker="[!] ${status}"
        else
            marker="[OK]"
        fi

        printf "  %-20s %8dG %8dG %8dG %5d%%  %s\n" "${name}" "${total_gb}" "${used_gb}" "${avail_gb}" "${pct}" "${marker}"
    done
    echo ""
}

auto_select_storage() {
    pvesm status 2>/dev/null | tail -n +2 | while read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local type=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local avail_kb=$(echo "$line" | awk '{print $6}')

        [ "${status}" != "active" ] && continue

        local content
        content=$(grep -A 5 "^${type}: ${name}$" /etc/pve/storage.cfg 2>/dev/null | grep -m1 "content " | awk '{$1=""; print $0}' | xargs || echo "")
        local supports_rootfs="no"
        if [ "${type}" = "lvmthin" ] || [ "${type}" = "zfspool" ]; then
            supports_rootfs="yes"
        elif [ "${type}" = "lvm" ] && echo "${content}" | grep -q "rootdir"; then
            supports_rootfs="yes"
        elif [ "${type}" = "dir" ] && echo "${content}" | grep -q "rootdir"; then
            supports_rootfs="yes"
        fi
        [ "${supports_rootfs}" != "yes" ] && continue

        echo "${avail_kb} ${name}"
    done | sort -rn | head -1 | awk '{print $2}'
}

check_storage_has_space() {
    local storage_name="$1"
    local needed_gb="$2"

    local line
    line=$(pvesm status 2>/dev/null | awk -v s="${storage_name}" '$1==s {print}' | head -1)

    if [ -z "${line}" ]; then
        echo "ERREUR : storage '${storage_name}' introuvable dans pvesm status"
        return 1
    fi

    local status=$(echo "$line" | awk '{print $3}')
    local avail_kb=$(echo "$line" | awk '{print $6}')
    local avail_gb=$((avail_kb / 1024 / 1024))

    if [ "${status}" != "active" ]; then
        echo "ERREUR : storage '${storage_name}' n'est pas actif (status : ${status})"
        return 1
    fi

    local needed_with_margin=$((needed_gb + SAFETY_MARGIN_GB))
    if [ "${avail_gb}" -lt "${needed_with_margin}" ]; then
        echo "ERREUR : storage '${storage_name}' n'a pas assez d'espace"
        echo "         Disponible : ${avail_gb} GB"
        echo "         Requis     : ${needed_gb} GB + ${SAFETY_MARGIN_GB} GB de marge = ${needed_with_margin} GB"
        return 1
    fi

    return 0
}

# Resoudre STORAGE=auto et verifier l'espace (mode CREATION uniquement)
if ! pct status "${CTID}" &>/dev/null; then
    show_storage_dashboard

    if [ "${STORAGE}" = "auto" ]; then
        echo "  STORAGE=auto -> selection automatique..."
        STORAGE=$(auto_select_storage)
        if [ -z "${STORAGE}" ]; then
            echo "  ERREUR : aucun storage actif compatible rootfs trouve."
            exit 1
        fi
        echo "  -> Storage selectionne : ${STORAGE}"
        echo ""
    fi

    echo "  Verification de l'espace sur ${STORAGE} (besoin : ${DISK_SIZE} GB + ${SAFETY_MARGIN_GB} GB de marge)..."
    if ! check_storage_has_space "${STORAGE}" "${DISK_SIZE}"; then
        echo ""
        echo "  -> Suggestion : utilisez le storage avec le plus d'espace libre"
        BEST_STORAGE=$(auto_select_storage)
        if [ -n "${BEST_STORAGE}" ] && [ "${BEST_STORAGE}" != "${STORAGE}" ]; then
            echo "     STORAGE=${BEST_STORAGE} $0 ${CTID} ${CT_NAME_RAW}"
        fi
        exit 1
    fi
    echo "  -> OK"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# PRE-REQUIS HOTE PROXMOX : modules kernel pour Swarm (--swarm uniquement)
# ══════════════════════════════════════════════════════════════════════════════
if [ "${SWARM_MODE}" -eq 1 ]; then
    echo "==========================================="
    echo "  Pre-requis hote Proxmox (modules Swarm)"
    echo "==========================================="

    SWARM_MODULES="ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack br_netfilter overlay"

    if [ ! -f /etc/modules-load.d/swarm.conf ]; then
        echo "  -> Configuration des modules au boot..."
        cat > /etc/modules-load.d/swarm.conf << 'EOF'
# Modules requis pour Docker Swarm (overlay networks, routing mesh)
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
br_netfilter
overlay
EOF
        echo "  -> /etc/modules-load.d/swarm.conf cree"
    else
        echo "  -> /etc/modules-load.d/swarm.conf deja present"
    fi

    echo "  -> Chargement des modules..."
    for mod in ${SWARM_MODULES}; do
        modprobe "${mod}" 2>/dev/null || echo "  -> ATTENTION : impossible de charger ${mod}"
    done

    KERNEL_MODULES_LOADED=$(lsmod | awk '{print $1}' | grep -cE '^(ip_vs|overlay|br_netfilter|nf_conntrack)$' || true)
    echo "  -> Modules charges : ${KERNEL_MODULES_LOADED}/4 (ip_vs/overlay/br_netfilter/nf_conntrack)"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# Detection mode : CREATION ou RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
if pct status "${CTID}" &>/dev/null; then
    MODE="reconfigure"
    echo "==========================================="
    echo "  Container ${CTID} detecte -> RECONFIGURATION"
else
    MODE="create"
    echo "==========================================="
    echo "  Container ${CTID} inexistant -> CREATION"
fi
[ "${DOCKER_MODE}" -eq 1 ] && echo "  Docker     : ACTIVE"
[ "${SWARM_MODE}" -eq 1 ] && echo "  Swarm-ready: ACTIVE"
[ "${INIT_SWARM}" -eq 1 ] && echo "  Init-Swarm : ACTIVE"
[ "${JOIN_SWARM}" -eq 1 ] && echo "  Join-Swarm : ACTIVE (manager=${JOIN_MANAGER_IP})"
echo "==========================================="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Fragments de configuration LXC (conditionnels selon les flags)
# ══════════════════════════════════════════════════════════════════════════════
write_docker_lxc_perms() {
    cat >> "${CONF}" << 'EOF'

# Docker dans LXC : permissions necessaires
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw cgroup:rw
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /sys/kernel/security sys/kernel/security none bind,optional 0 0
EOF
}

write_swarm_lxc_perms() {
    cat >> "${CONF}" << 'EOF'

# Docker Swarm : overlay network (VXLAN) requiert /dev/net/tun
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
EOF
}

build_tags_create() {
    local tags="agflow"
    [ "${DOCKER_MODE}" -eq 1 ] && tags="${tags},docker"
    [ "${SWARM_MODE}" -eq 1 ] && tags="${tags},swarm-ready"
    echo "${tags}"
}

build_description_create() {
    if [ "${DOCKER_MODE}" -eq 1 ] && [ "${SWARM_MODE}" -eq 1 ]; then
        echo "agflow.docker platform (Swarm node)"
    elif [ "${DOCKER_MODE}" -eq 1 ]; then
        echo "agflow.docker platform"
    elif [ "${SWARM_MODE}" -eq 1 ]; then
        echo "agflow LXC (Swarm node)"
    else
        echo "agflow LXC"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# MODE CREATION
# ══════════════════════════════════════════════════════════════════════════════
if [ "${MODE}" = "create" ]; then

    TEMPLATE=$(pveam list local 2>/dev/null | grep -i "ubuntu-24" | awk '{print $1}' | head -1)
    [ -z "${TEMPLATE}" ] && TEMPLATE=$(pveam list local 2>/dev/null | grep -i "ubuntu-22" | awk '{print $1}' | head -1)
    [ -z "${TEMPLATE}" ] && TEMPLATE=$(pveam list local 2>/dev/null | grep -i "ubuntu" | awk '{print $1}' | head -1)

    if [ -z "${TEMPLATE}" ]; then
        echo "ERREUR : Aucun template Ubuntu trouve."
        echo ""
        echo "Templates disponibles :"
        pveam list local
        echo ""
        echo "Pour telecharger Ubuntu 24.04 :"
        echo "  pveam update"
        echo "  pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
        exit 1
    fi

    CT_TAGS=$(build_tags_create)
    CT_DESCRIPTION=$(build_description_create)

    echo "  CT ID    : ${CTID}"
    echo "  Nom      : ${CT_NAME}"
    echo "  CPU      : ${CORES} coeurs"
    echo "  RAM      : ${MEMORY} MB"
    echo "  Swap     : ${SWAP} MB"
    echo "  Disque   : ${DISK_SIZE}G"
    echo "  Storage  : ${STORAGE}"
    echo "  Reseau   : ${BRIDGE}"
    echo "  Template : ${TEMPLATE}"
    echo "  Tags     : ${CT_TAGS}"
    echo ""

    echo "[1/3] Creation du container LXC..."
    pct create "${CTID}" "${TEMPLATE}" \
      --hostname "${CT_NAME}" \
      --cores "${CORES}" \
      --memory "${MEMORY}" \
      --swap "${SWAP}" \
      --rootfs "${STORAGE}:${DISK_SIZE}" \
      --net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=dhcp,type=veth" \
      --nameserver "8.8.8.8" \
      --searchdomain "1.1.1.1" \
      --ostype ubuntu \
      --unprivileged 0 \
      --features "nesting=1,keyctl=1" \
      --tags "${CT_TAGS}" \
      --description "${CT_DESCRIPTION}"
    echo "  -> Container cree"

    echo "[2/3] Ajout des permissions LXC selon les flags..."
    if [ "${DOCKER_MODE}" -eq 1 ]; then
        write_docker_lxc_perms
        echo "  -> Permissions Docker ajoutees"
    fi
    if [ "${SWARM_MODE}" -eq 1 ]; then
        write_swarm_lxc_perms
        echo "  -> Permissions Swarm ajoutees"
    fi
    if [ "${DOCKER_MODE}" -eq 0 ] && [ "${SWARM_MODE}" -eq 0 ]; then
        echo "  -> Aucune permission (LXC nu)"
    fi

    STEP_BOOT=3
    STEP_TOTAL=3

# ══════════════════════════════════════════════════════════════════════════════
# MODE RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
else

    WAS_UNPRIVILEGED=0
    if grep -q "^unprivileged: 1" "${CONF}" 2>/dev/null; then
        WAS_UNPRIVILEGED=1
        echo "  [!] Container actuellement unprivileged -> sera converti en privileged"
        echo "      Les UIDs/GIDs du systeme de fichiers seront corriges automatiquement."
        echo ""
    fi

    echo "[1/6] Arret du container ${CTID}..."
    pct stop "${CTID}" 2>/dev/null || true
    sleep 3
    echo "  -> Arrete"

    echo "[2/6] Backup de la configuration..."
    CONF_BACKUP_PATH="${CONF}.backup.$(date +%Y%m%d%H%M%S)"
    cp "${CONF}" "${CONF_BACKUP_PATH}"
    echo "  -> Backup : ${CONF_BACKUP_PATH}"

    echo "[3/6] Lecture des parametres existants..."
    ARCH=$(grep "^arch:" "${CONF}" | head -1 || echo "arch: amd64")
    CORES_CONF=$(grep "^cores:" "${CONF}" | head -1 || echo "cores: 4")
    HOSTNAME_CONF=$(grep "^hostname:" "${CONF}" | head -1 || echo "hostname: docker-lxc")
    MEMORY_CONF=$(grep "^memory:" "${CONF}" | head -1 || echo "memory: 8192")
    NAMESERVER=$(grep "^nameserver:" "${CONF}" | head -1 || echo "nameserver: 8.8.8.8")
    NET0=$(grep "^net0:" "${CONF}" | head -1 || echo "")
    OSTYPE=$(grep "^ostype:" "${CONF}" | head -1 || echo "ostype: ubuntu")
    ROOTFS=$(grep "^rootfs:" "${CONF}" | head -1 || echo "")
    SEARCHDOMAIN=$(grep "^searchdomain:" "${CONF}" | head -1 || echo "searchdomain: 1.1.1.1")
    SWAP_CONF=$(grep "^swap:" "${CONF}" | head -1 || echo "swap: 1024")
    EXISTING_TAGS=$(grep "^tags:" "${CONF}" | head -1 | sed 's/^tags: //' || echo "")
    echo "  -> ${HOSTNAME_CONF}"
    echo "  -> ${CORES_CONF}, ${MEMORY_CONF}"

    if [ "${WAS_UNPRIVILEGED}" -eq 1 ]; then
        echo "[4/6] Correction des UIDs/GIDs (unprivileged -> privileged)..."

        pct mount "${CTID}" 2>&1 || true
        MOUNTPOINT="/var/lib/lxc/${CTID}/rootfs"

        if [ ! -d "${MOUNTPOINT}" ]; then
            echo "  -> ERREUR : impossible de trouver le rootfs monte sur ${MOUNTPOINT}"
            echo "     Verifiez manuellement : pct mount ${CTID}"
            exit 1
        fi

        echo "  -> Rootfs monte sur : ${MOUNTPOINT}"

        COUNT_UID=$(find "${MOUNTPOINT}" -uid 100000 2>/dev/null | head -100 | wc -l)
        echo "  -> Fichiers avec UID 100000 detectes : ${COUNT_UID}+"

        if [ "${COUNT_UID}" -gt 0 ]; then
            echo "  -> Remapping UIDs 100000-165535 vers 0-65535..."
            cd "${MOUNTPOINT}"
            find . -wholename ./proc -prune -o -wholename ./sys -prune -o -print0 2>/dev/null | \
            while IFS= read -r -d '' file; do
                FUID=$(stat -c '%u' "$file" 2>/dev/null) || continue
                FGID=$(stat -c '%g' "$file" 2>/dev/null) || continue
                NEW_UID="${FUID}"
                NEW_GID="${FGID}"
                if [ "${FUID}" -ge 100000 ] && [ "${FUID}" -le 165535 ]; then
                    NEW_UID=$((FUID - 100000))
                fi
                if [ "${FGID}" -ge 100000 ] && [ "${FGID}" -le 165535 ]; then
                    NEW_GID=$((FGID - 100000))
                fi
                if [ "${NEW_UID}" != "${FUID}" ] || [ "${NEW_GID}" != "${FGID}" ]; then
                    chown -h "${NEW_UID}:${NEW_GID}" "$file" 2>/dev/null || true
                fi
            done
            cd /
            echo "  -> Remapping termine"
        else
            echo "  -> Pas de remapping necessaire (UIDs deja corrects)"
        fi

        pct unmount "${CTID}"
        echo "  -> Rootfs demonte"
    else
        echo "[4/6] Deja privileged, pas de remapping UIDs."
    fi

    # Calculer les tags : ajouter docker / swarm-ready selon les flags
    NEW_TAGS="${EXISTING_TAGS}"
    if [ "${DOCKER_MODE}" -eq 1 ] && ! echo "${NEW_TAGS}" | grep -q "docker"; then
        [ -z "${NEW_TAGS}" ] && NEW_TAGS="agflow;docker" || NEW_TAGS="${NEW_TAGS};docker"
    fi
    if [ "${SWARM_MODE}" -eq 1 ] && ! echo "${NEW_TAGS}" | grep -q "swarm-ready"; then
        [ -z "${NEW_TAGS}" ] && NEW_TAGS="agflow;swarm-ready" || NEW_TAGS="${NEW_TAGS};swarm-ready"
    fi
    if [ -z "${NEW_TAGS}" ]; then
        NEW_TAGS="agflow"
    fi
    TAGS_LINE="tags: ${NEW_TAGS}"

    echo "[5/6] Ecriture de la configuration..."
    cat > "${CONF}" << EOF
${ARCH}
${CORES_CONF}
features: nesting=1,keyctl=1
${HOSTNAME_CONF}
${MEMORY_CONF}
${NAMESERVER}
${NET0}
${OSTYPE}
${ROOTFS}
${SEARCHDOMAIN}
${SWAP_CONF}
${TAGS_LINE}
unprivileged: 0
EOF

    if [ "${DOCKER_MODE}" -eq 1 ]; then
        write_docker_lxc_perms
        echo "  -> Permissions Docker ajoutees"
    fi
    if [ "${SWARM_MODE}" -eq 1 ]; then
        write_swarm_lxc_perms
        echo "  -> Permissions Swarm ajoutees"
    fi
    if [ "${DOCKER_MODE}" -eq 0 ] && [ "${SWARM_MODE}" -eq 0 ]; then
        echo "  -> Aucune permission additionnelle (LXC nu)"
    fi

    sed -i '/./,$!d' "${CONF}"

    STEP_BOOT=6
    STEP_TOTAL=6
fi

# ══════════════════════════════════════════════════════════════════════════════
# COMMUN : Demarrage + Reseau + apt + SSH + agflow
# ══════════════════════════════════════════════════════════════════════════════

echo "[${STEP_BOOT}/${STEP_TOTAL}] Demarrage du container..."
pct start "${CTID}"
sleep 5

if pct status "${CTID}" | grep -q running; then
    echo "  -> Container demarre"
else
    echo "  -> ERREUR : Container ne demarre pas. Verifiez les logs :"
    echo "     journalctl -xe | grep ${CTID}"
    exit 1
fi

# ── Configuration reseau DHCP ────────────────────────────────────────────────
echo ""
echo "  Configuration reseau DHCP..."
pct exec "${CTID}" -- bash -c '
if [ ! -f /etc/systemd/network/20-eth0.network ]; then
    cat > /etc/systemd/network/20-eth0.network << NETEOF
[Match]
Name=eth0

[Network]
DHCP=yes

[DHCP]
UseDNS=yes
UseRoutes=yes
NETEOF
    systemctl restart systemd-networkd
    echo "  -> Configuration DHCP creee"
else
    echo "  -> Configuration DHCP deja presente"
fi

sleep 5
IP=$(ip -4 addr show eth0 2>/dev/null | grep inet | awk "{print \$2}" | head -1)
if [ -n "$IP" ]; then
    echo "  -> IP obtenue : $IP"
else
    echo "  -> ATTENTION : pas d IP obtenue. Verifiez le DHCP."
fi

if ping -c 1 8.8.8.8 &>/dev/null; then
    echo "  -> Internet : OK"
else
    echo "  -> ATTENTION : pas de connectivite internet"
fi
'

# ── Configuration sysctl Swarm dans le container (si --swarm) ────────────────
if [ "${SWARM_MODE}" -eq 1 ]; then
    echo ""
    echo "  Configuration sysctl Swarm dans le container..."
    pct exec "${CTID}" -- bash -c '
cat > /etc/sysctl.d/99-swarm.conf << SYSEOF
# Forwarding IP requis pour Docker et overlay networks Swarm
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1

# Conntrack pour les overlay networks (eviter la saturation sur charge)
net.netfilter.nf_conntrack_max=131072

# Buffers UDP plus larges (VXLAN encapsule en UDP/4789)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
SYSEOF

sysctl --system >/dev/null 2>&1 || true
echo "  -> /etc/sysctl.d/99-swarm.conf cree et applique"
'

    pct exec "${CTID}" -- bash -c "
if [ -c /dev/net/tun ]; then
    echo '  -> /dev/net/tun present : OK (VXLAN ready)'
else
    echo '  -> ATTENTION : /dev/net/tun absent. VXLAN ne fonctionnera pas.'
    echo '     Verifiez la configuration LXC : grep tun ${CONF}'
fi
"
fi

# ── apt update + upgrade + paquets de base + SSH (consolide) ─────────────────
echo ""
echo "  Mise a jour et installation des paquets de base + SSH..."

mkdir -p "${SSH_KEY_DIR}"

KEY_FILE="${SSH_KEY_DIR}/id_ed25519_lxc${CTID}"
if [ -f "${KEY_FILE}" ]; then
    echo "  -> Clef SSH existante : ${KEY_FILE}"
else
    echo "  -> Generation de la clef SSH..."
    ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "proxmox-host->lxc-${CTID}" -q
    echo "  -> Clef generee : ${KEY_FILE}"
fi

PUB_KEY=$(cat "${KEY_FILE}.pub")

pct exec "${CTID}" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
APT_OPTS='-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef'

apt-get update -qq
apt-get \${APT_OPTS} upgrade -y -qq

# Paquets de base + SSH (un seul apt-get install)
apt-get \${APT_OPTS} install -y -qq \\
  curl wget git vim htop tmux \\
  ca-certificates gnupg lsb-release \\
  python3 python3-pip python3-venv \\
  openssh-server \\
  unattended-upgrades apt-listchanges

# Configuration unattended-upgrades (security only, Docker exclus)
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    \"\${distro_id}:\${distro_codename}-security\";
    \"\${distro_id}ESMApps:\${distro_codename}-apps-security\";
    \"\${distro_id}ESM:\${distro_codename}-infra-security\";
};
Unattended-Upgrade::Package-Blacklist {
    // Docker mis a jour manuellement
    \"docker-ce\";
    \"docker-ce-cli\";
    \"containerd.io\";
};
Unattended-Upgrade::AutoFixInterruptedDpkg \"true\";
Unattended-Upgrade::MinimalSteps \"true\";
Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
Unattended-Upgrade::Automatic-Reboot \"false\";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists \"1\";
APT::Periodic::Unattended-Upgrade \"1\";
APT::Periodic::AutocleanInterval \"7\";
EOF

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl restart unattended-upgrades >/dev/null 2>&1 || true

# Configuration SSH (openssh-server est deja installe ci-dessus)
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if ! grep -qF '${PUB_KEY}' /root/.ssh/authorized_keys 2>/dev/null; then
    echo '${PUB_KEY}' >> /root/.ssh/authorized_keys
    echo '  -> Clef publique injectee'
else
    echo '  -> Clef publique deja presente'
fi
chmod 600 /root/.ssh/authorized_keys

systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
echo '  -> sshd demarre'
"

# ── Creer l'utilisateur agflow avec clef SSH ─────────────────────────────────
echo ""
echo "  Creation de l'utilisateur agflow..."

AGFLOW_PASS=$(tr -dc 'A-Za-z0-9_!@#$%^&*' </dev/urandom 2>/dev/null | head -c 24 || echo "agflow$(date +%s)")

AGFLOW_KEY_FILE="${SSH_KEY_DIR}/id_ed25519_agflow_lxc${CTID}"
if [ ! -f "${AGFLOW_KEY_FILE}" ]; then
    ssh-keygen -t ed25519 -f "${AGFLOW_KEY_FILE}" -N "" -C "agflow@lxc-${CTID}" -q
    echo "  -> Clef agflow generee : ${AGFLOW_KEY_FILE}"
else
    echo "  -> Clef agflow existante : ${AGFLOW_KEY_FILE}"
fi
AGFLOW_PUB_KEY=$(cat "${AGFLOW_KEY_FILE}.pub")

# Groupes : sudo toujours, docker uniquement si --docker
AGFLOW_GROUPS_CMD="sudo"
[ "${DOCKER_MODE}" -eq 1 ] && AGFLOW_GROUPS_CMD="sudo,docker"

pct exec "${CTID}" -- bash -c "
if ! id agflow &>/dev/null; then
    useradd -m -s /bin/bash -G ${AGFLOW_GROUPS_CMD} agflow 2>/dev/null || useradd -m -s /bin/bash agflow
    echo '  -> Utilisateur agflow cree'
else
    echo '  -> Utilisateur agflow existant'
    # S'assurer que les groupes sont a jour
    for grp in \$(echo '${AGFLOW_GROUPS_CMD}' | tr ',' ' '); do
        getent group \"\${grp}\" >/dev/null 2>&1 && usermod -aG \"\${grp}\" agflow 2>/dev/null || true
    done
fi

echo 'agflow:${AGFLOW_PASS}' | chpasswd
echo '  -> Mot de passe agflow configure'

mkdir -p /home/agflow/.ssh
chmod 700 /home/agflow/.ssh

if ! grep -qF '${AGFLOW_PUB_KEY}' /home/agflow/.ssh/authorized_keys 2>/dev/null; then
    echo '${AGFLOW_PUB_KEY}' >> /home/agflow/.ssh/authorized_keys
    echo '  -> Clef publique agflow injectee'
else
    echo '  -> Clef publique agflow deja presente'
fi
chmod 600 /home/agflow/.ssh/authorized_keys
chown -R agflow:agflow /home/agflow/.ssh

echo 'agflow ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agflow
chmod 440 /etc/sudoers.d/agflow
echo '  -> sudo NOPASSWD configure'
"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALLATION DOCKER (si --docker)
# Le contenu de 01-install-docker.sh est inline ci-dessous, sans la duplication
# de openssh-server / apt update / unattended-upgrades (deja faits ci-dessus).
# ══════════════════════════════════════════════════════════════════════════════
if [ "${DOCKER_MODE}" -eq 1 ]; then
    echo ""
    echo "==========================================="
    echo "  Installation Docker"
    echo "==========================================="

    if [ "${LIVE_RESTORE}" = "1" ]; then
        LIVE_RESTORE_VAL="true"
    else
        LIVE_RESTORE_VAL="false"
    fi

    # Generer le script d'install dans un temp file (heredoc non-interpole)
    # puis pct push + pct exec. Evite tous les problemes d'echappement
    # multi-niveaux (bash -c imbrique, $VERSION_CODENAME, etc.).
    DOCKER_INSTALL_TMP="$(mktemp /tmp/install-docker.XXXXXX.sh)"
    cat > "${DOCKER_INSTALL_TMP}" << 'DOCKER_INSTALL_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

MIN_FREE_MB="${MIN_FREE_MB:-1024}"
LIVE_RESTORE_VAL="${LIVE_RESTORE_VAL:-false}"
DOCKER_ADDR_POOL="${DOCKER_ADDR_POOL:-172.30.0.0/16}"
DOCKER_ADDR_POOL_SIZE="${DOCKER_ADDR_POOL_SIZE:-24}"

# Verification espace disque
free_mb=$(df --output=avail -BM / | tail -1 | tr -d 'M ')
if [ "${free_mb}" -lt "${MIN_FREE_MB}" ]; then
    echo "ERREUR : espace disque insuffisant (${free_mb} MB libre, ${MIN_FREE_MB} MB requis)"
    echo "Solutions :"
    echo "  - Liberer : apt clean && rm -rf /tmp/* /var/cache/apt/archives/*.deb"
    echo "  - Etendre rootfs depuis l hote : pct resize <CTID> rootfs +10G"
    exit 1
fi
echo "  -> Espace disque libre : ${free_mb} MB (OK)"

# Repository Docker
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
echo "  -> Docker Engine installe"

# Configuration Docker (daemon.json)
mkdir -p /etc/docker
tee /etc/docker/daemon.json > /dev/null << DAEMON_JSON_EOF
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
DAEMON_JSON_EOF

systemctl enable docker >/dev/null 2>&1
systemctl restart docker
echo "  -> Configuration Docker appliquee (live-restore=${LIVE_RESTORE_VAL}, pool=${DOCKER_ADDR_POOL}/${DOCKER_ADDR_POOL_SIZE})"

# Nettoyage
apt-get clean
apt-get autoremove -y -qq 2>/dev/null || true
DOCKER_INSTALL_EOF

    pct push "${CTID}" "${DOCKER_INSTALL_TMP}" /root/install-docker.sh
    pct exec "${CTID}" -- chmod +x /root/install-docker.sh

    if pct exec "${CTID}" -- env \
        MIN_FREE_MB="${MIN_FREE_MB}" \
        LIVE_RESTORE_VAL="${LIVE_RESTORE_VAL}" \
        DOCKER_ADDR_POOL="${DOCKER_ADDR_POOL}" \
        DOCKER_ADDR_POOL_SIZE="${DOCKER_ADDR_POOL_SIZE}" \
        /root/install-docker.sh; then
        DOCKER_INSTALL_OK=1
    else
        DOCKER_INSTALL_OK=0
        echo "  [!] L'installation Docker a echoue (code != 0)"
    fi

    rm -f "${DOCKER_INSTALL_TMP}"

    # Verification post-installation
    echo ""
    echo "  Verification post-installation Docker..."

    if pct exec "${CTID}" -- bash -c "command -v docker >/dev/null && docker info >/dev/null 2>&1"; then
        DOCKER_OK=1
        echo "  -> Docker daemon : OK (operationnel)"

        if pct exec "${CTID}" -- docker run --rm hello-world >/dev/null 2>&1; then
            DOCKER_HELLO_OK=1
            echo "  -> Docker run    : OK (test hello-world reussi)"
        else
            DOCKER_HELLO_OK=0
            echo "  -> Docker run    : ECHEC (probleme reseau ou pull registry)"
        fi
    else
        DOCKER_OK=0
        echo "  -> ERREUR : Docker n'est pas operationnel."
        echo "     Causes : pool sature, repo inaccessible, conflit de paquets..."
        pct exec "${CTID}" -- df -h / 2>/dev/null | tail -n +2 | sed 's/^/    /'
    fi

    # Verification finale Swarm-ready (uniquement si --swarm)
    if [ "${SWARM_MODE}" -eq 1 ]; then
        TUN_OK=$(pct exec "${CTID}" -- bash -c "[ -c /dev/net/tun ] && echo yes || echo no" 2>/dev/null || echo "no")
        if [ "${TUN_OK}" = "yes" ] && [ "${DOCKER_OK}" -eq 1 ]; then
            SWARM_READY="true"
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# INIT SWARM (si --init-swarm)
# ══════════════════════════════════════════════════════════════════════════════
INIT_SWARM_OK=0
if [ "${INIT_SWARM}" -eq 1 ]; then
    echo ""
    echo "==========================================="
    echo "  Initialisation Swarm Manager"
    echo "==========================================="

    # Pre-check : Docker doit etre operationnel
    if [ "${DOCKER_OK}" -ne 1 ]; then
        fail "Docker n'est pas operationnel, impossible d'initialiser Swarm"
    fi

    # Verifier l'etat Swarm courant
    SWARM_PRE_STATE=$(pct exec "${CTID}" -- bash -c "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null || echo "unknown")

    if [ "${SWARM_PRE_STATE}" = "active" ]; then
        if [ "${FORCE}" -eq 1 ]; then
            echo "  -> Swarm deja actif, FORCE=1 : leave force..."
            pct exec "${CTID}" -- docker swarm leave --force >/dev/null 2>&1 || true
            echo "  -> Swarm reinitialise"
        else
            echo "  -> Swarm deja actif sur ce LXC."
            pct exec "${CTID}" -- docker node ls 2>/dev/null | sed 's/^/    /' || true
            echo "  Pour reinitialiser (DETRUIT le cluster) : FORCE=1 $0 ${CTID}"
            INIT_SWARM_OK=2  # 2 = deja actif, pas une erreur
        fi
    fi

    if [ "${INIT_SWARM_OK}" -ne 2 ]; then
        # Detection + correction live-restore
        echo ""
        echo "  Verification live-restore..."
        LIVE_RESTORE_ON=$(pct exec "${CTID}" -- bash -c "
if [ -f /etc/docker/daemon.json ]; then
    grep -q '\"live-restore\"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json && echo yes || echo no
else
    echo no
fi
" 2>/dev/null || echo "no")

        if [ "${LIVE_RESTORE_ON}" = "yes" ]; then
            if [ "${AUTO_FIX}" -eq 1 ]; then
                echo "  -> live-restore=true detecte, correction..."
                pct exec "${CTID}" -- bash -c "
sed -i 's/\"live-restore\":[[:space:]]*true/\"live-restore\": false/' /etc/docker/daemon.json
systemctl reload docker 2>/dev/null || systemctl restart docker
" || fail "Impossible de corriger live-restore"
                sleep 2
                LIVE_RESTORE_FIXED=1
                echo "  -> live-restore : false (compatible Swarm)"
            else
                fail "live-restore=true detecte" "Relancez avec AUTO_FIX=1"
            fi
        else
            echo "  -> live-restore : false (compatible Swarm) : OK"
        fi

        # Detection IP advertise
        if [ -n "${ADVERTISE_ADDR:-}" ]; then
            echo "  -> IP forcee via env : ${ADVERTISE_ADDR}"
        else
            ADVERTISE_ADDR=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")
            if [ -z "${ADVERTISE_ADDR}" ]; then
                fail "Impossible de detecter l'IP du LXC sur eth0" "Forcez : ADVERTISE_ADDR=<ip>"
            fi
            echo "  -> IP detectee (eth0) : ${ADVERTISE_ADDR}"
        fi
        ADVERTISE_ADDR_USED="${ADVERTISE_ADDR}"

        # Verification conflit pool overlay
        POOL_PREFIX=$(echo "${POOL_OVERLAY}" | cut -d. -f1-2)
        ADV_PREFIX=$(echo "${ADVERTISE_ADDR}" | cut -d. -f1-2)
        if [ "${POOL_PREFIX}" = "${ADV_PREFIX}" ]; then
            echo "  -> ATTENTION : pool overlay (${POOL_OVERLAY}) chevauche le subnet du LXC (${ADVERTISE_ADDR})"
        fi

        # Initialisation
        echo "  -> Initialisation Swarm..."
        INIT_OUTPUT=$(pct exec "${CTID}" -- docker swarm init \
            --advertise-addr "${ADVERTISE_ADDR}" \
            --listen-addr "${ADVERTISE_ADDR}:2377" \
            --default-addr-pool "${POOL_OVERLAY}" \
            --default-addr-pool-mask-length "${POOL_MASK}" 2>&1)
        INIT_RC=$?

        if [ ${INIT_RC} -ne 0 ]; then
            echo "  ECHEC docker swarm init (code ${INIT_RC}) :"
            echo "${INIT_OUTPUT}" | sed 's/^/    /'
            fail "Initialisation Swarm echouee"
        fi

        echo "  -> Swarm initialise"

        # Recuperer les tokens
        WORKER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token worker -q 2>/dev/null)
        MANAGER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token manager -q 2>/dev/null)

        if [ -z "${WORKER_TOKEN}" ] || [ -z "${MANAGER_TOKEN}" ]; then
            fail "Impossible de recuperer les tokens"
        fi

        mkdir -p "${TOKEN_DIR}"
        TOKEN_FILE="${TOKEN_DIR}/swarm-tokens-${CTID}.json"
        cat > "${TOKEN_FILE}" << EOF
{
  "manager_ctid": "${CTID}",
  "manager_ip": "${ADVERTISE_ADDR}",
  "manager_port": 2377,
  "worker_token": "${WORKER_TOKEN}",
  "manager_token": "${MANAGER_TOKEN}",
  "pool_overlay": "${POOL_OVERLAY}",
  "pool_mask": "${POOL_MASK}",
  "init_date": "$(date -Iseconds)"
}
EOF
        chmod 600 "${TOKEN_FILE}"
        echo "  -> Tokens sauvegardes : ${TOKEN_FILE}"

        # Labels du node
        NODE_ID=$(pct exec "${CTID}" -- docker node ls --format '{{.ID}}' 2>/dev/null | head -1)
        if [ -n "${NODE_ID}" ] && [ -n "${NODE_LABELS}" ]; then
            IFS=',' read -ra LABELS_ARRAY <<< "${NODE_LABELS}"
            LABEL_ARGS=""
            for lbl in "${LABELS_ARRAY[@]}"; do
                LABEL_ARGS="${LABEL_ARGS} --label-add ${lbl}"
            done
            # shellcheck disable=SC2086
            pct exec "${CTID}" -- docker node update ${LABEL_ARGS} "${NODE_ID}" >/dev/null 2>&1 || \
                echo "  -> ATTENTION : echec de la pose des labels"
            echo "  -> Labels poses : ${NODE_LABELS}"
        fi

        INIT_SWARM_OK=1
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# JOIN SWARM (si --join-swarm)
# ══════════════════════════════════════════════════════════════════════════════
JOIN_SWARM_OK=0
if [ "${JOIN_SWARM}" -eq 1 ]; then
    echo ""
    echo "==========================================="
    echo "  Join Swarm cluster"
    echo "==========================================="

    if [ "${DOCKER_OK}" -ne 1 ]; then
        fail "Docker n'est pas operationnel, impossible de rejoindre Swarm"
    fi

    if [ "${JOIN_AS_MANAGER}" -eq 1 ]; then
        JOIN_ROLE="manager"
    else
        JOIN_ROLE="worker"
    fi

    # Auto-detect ADVERTISE_ADDR si non fourni
    if [ -z "${ADVERTISE_ADDR_USED}" ]; then
        if [ -n "${ADVERTISE_ADDR:-}" ]; then
            ADVERTISE_ADDR_USED="${ADVERTISE_ADDR}"
        else
            ADVERTISE_ADDR_USED=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")
            if [ -z "${ADVERTISE_ADDR_USED}" ]; then
                fail "Impossible de detecter l'IP du LXC" "Specifiez ADVERTISE_ADDR=<ip>"
            fi
        fi
    fi

    echo "  Manager IP : ${JOIN_MANAGER_IP}:2377"
    echo "  Role       : ${JOIN_ROLE}"
    echo "  Advertise  : ${ADVERTISE_ADDR_USED}"
    echo "  Listen     : ${LISTEN_ADDR_JOIN}"

    # Verifier l'etat Swarm courant
    SWARM_PRE_STATE=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
    if [ "${SWARM_PRE_STATE}" = "active" ]; then
        if [ "${FORCE_LEAVE}" = "yes" ]; then
            echo "  -> Swarm deja actif, FORCE_LEAVE=yes : leave force..."
            pct exec "${CTID}" -- docker swarm leave --force >/dev/null 2>&1 || true
            sleep 2
        else
            fail "LXC ${CTID} deja dans un Swarm actif" "Relancez avec FORCE_LEAVE=yes"
        fi
    fi

    # Test connectivite
    echo "  Test de connectivite vers ${JOIN_MANAGER_IP}:2377..."
    if pct exec "${CTID}" -- bash -c "timeout 5 bash -c '</dev/tcp/${JOIN_MANAGER_IP}/2377' 2>/dev/null"; then
        echo "  -> Manager joignable"
    else
        fail "Impossible de joindre ${JOIN_MANAGER_IP}:2377" \
             "Verifiez : firewall (port 2377 TCP, 4789 UDP, 7946 TCP+UDP), IP correcte"
    fi

    # Join
    echo "  -> Rejoindre comme ${JOIN_ROLE}..."
    JOIN_OUTPUT=$(pct exec "${CTID}" -- docker swarm join \
        --advertise-addr "${ADVERTISE_ADDR_USED}" \
        --listen-addr "${LISTEN_ADDR_JOIN}" \
        --token "${JOIN_TOKEN}" \
        "${JOIN_MANAGER_IP}:2377" 2>&1)
    JOIN_RC=$?

    if [ ${JOIN_RC} -ne 0 ]; then
        echo "  Sortie : ${JOIN_OUTPUT}"
        fail "Echec du join Swarm" "Token, IP manager, ou role incorrect"
    fi
    echo "  -> ${JOIN_OUTPUT}"

    sleep 3
    JOIN_NEW_STATE=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
    JOIN_NEW_ROLE=$(pct exec "${CTID}" -- docker info --format '{{if .Swarm.ControlAvailable}}manager{{else}}worker{{end}}' 2>/dev/null || echo "unknown")
    JOIN_NODE_ID=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.NodeID}}' 2>/dev/null || echo "")

    if [ "${JOIN_NEW_STATE}" = "active" ]; then
        echo "  -> Etat Swarm : ${JOIN_NEW_STATE}"
        echo "  -> Role       : ${JOIN_NEW_ROLE}"
        echo "  -> Node ID    : ${JOIN_NODE_ID}"
        JOIN_SWARM_OK=1
    else
        echo "  -> ATTENTION : etat Swarm inattendu : ${JOIN_NEW_STATE}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Recuperation infos systeme (pour JSON)
# ══════════════════════════════════════════════════════════════════════════════
CT_IP=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")

IP_TYPE=$(pct exec "${CTID}" -- bash -c "
if [ -f /etc/systemd/network/20-eth0.network ] && grep -q 'DHCP=yes' /etc/systemd/network/20-eth0.network 2>/dev/null; then
    echo 'dhcp'
elif grep -q 'dhcp' /etc/netplan/*.yaml 2>/dev/null; then
    echo 'dhcp'
elif grep -q 'inet dhcp' /etc/network/interfaces 2>/dev/null; then
    echo 'dhcp'
else
    echo 'static'
fi
" 2>/dev/null || echo "unknown")

CT_DISTRO=$(pct exec "${CTID}" -- bash -c "
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo \"\${NAME} \${VERSION_ID}\"
else
    echo 'unknown'
fi
" 2>/dev/null || echo "unknown")

NODE_HOSTNAME=$(pct exec "${CTID}" -- hostname 2>/dev/null || echo "")

if [ "${DOCKER_MODE}" -eq 1 ]; then
    docker_version=$(pct exec "${CTID}" -- docker --version 2>/dev/null || echo "non installe")
    compose_version=$(pct exec "${CTID}" -- docker compose version 2>/dev/null || echo "non installe")
else
    docker_version=""
    compose_version=""
fi

# ══════════════════════════════════════════════════════════════════════════════
# Resume final
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==========================================="
echo "  Container ${CTID} : ${MODE^^} terminee"
echo "==========================================="
echo "  Distribution : ${CT_DISTRO}"
echo "  IP           : ${CT_IP} (${IP_TYPE})"
echo "  Acces        : pct enter ${CTID}"
[ -n "${CT_IP}" ] && echo "                 ssh -i ${KEY_FILE} root@${CT_IP}"
echo ""
echo "  agflow user  : ${AGFLOW_PASS}"
[ -n "${CT_IP}" ] && echo "                 ssh -i ${AGFLOW_KEY_FILE} agflow@${CT_IP}"
if [ "${DOCKER_MODE}" -eq 1 ]; then
    echo "  Docker       : ${docker_version} (operationnel=${DOCKER_OK})"
fi
if [ "${INIT_SWARM}" -eq 1 ] && [ "${INIT_SWARM_OK}" -eq 1 ]; then
    echo "  Swarm        : initialise sur ${ADVERTISE_ADDR_USED}:2377"
    echo "  Tokens       : ${TOKEN_FILE}"
fi
if [ "${JOIN_SWARM}" -eq 1 ] && [ "${JOIN_SWARM_OK}" -eq 1 ]; then
    echo "  Swarm        : rejoint comme ${JOIN_NEW_ROLE} (manager=${JOIN_MANAGER_IP})"
fi
echo "==========================================="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# JSON UNIFIE FINAL
# ══════════════════════════════════════════════════════════════════════════════
PROXMOX_HOST=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SCRIPT_VERSION="unknown"
if [ -n "${SCRIPT_DIR:-}" ]; then
    SCRIPT_VERSION=$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi

# Statut global
OVERALL_STATUS="ok"
EXIT_CODE=0

if [ "${DOCKER_MODE}" -eq 1 ] && [ "${DOCKER_OK}" -ne 1 ]; then
    OVERALL_STATUS="partial"
    EXIT_CODE=2
fi
if [ "${INIT_SWARM}" -eq 1 ] && [ "${INIT_SWARM_OK}" -eq 0 ]; then
    OVERALL_STATUS="failed"
    EXIT_CODE=1
fi
if [ "${JOIN_SWARM}" -eq 1 ] && [ "${JOIN_SWARM_OK}" -eq 0 ]; then
    OVERALL_STATUS="failed"
    EXIT_CODE=1
fi

# ── Bloc machine (toujours present) ──────────────────────────────────────────
MACHINE_GROUPS_JSON='["sudo"]'
if [ "${DOCKER_MODE}" -eq 1 ]; then
    MACHINE_GROUPS_JSON='["sudo","docker"]'
fi

build_machine_json() {
    printf '{'
    printf '"type":"lxc",'
    printf '"ctid":"%s","hostname":"%s","hostname_raw":"%s",' \
        "$(json_escape "${CTID}")" \
        "$(json_escape "${CT_NAME}")" \
        "$(json_escape "${CT_NAME_RAW}")"
    printf '"mode":"%s",' "${MODE}"
    printf '"ressources":{"cores":%s,"memory":%s,"swap":%s,"disk_size":%s,"storage":"%s","bridge":"%s"},' \
        "${CORES}" "${MEMORY}" "${SWAP}" "${DISK_SIZE}" \
        "$(json_escape "${STORAGE}")" \
        "$(json_escape "${BRIDGE}")"
    printf '"systeme":{"distro":"%s","ip":"%s","ip_type":"%s"},' \
        "$(json_escape "${CT_DISTRO}")" \
        "$(json_escape "${CT_IP}")" \
        "$(json_escape "${IP_TYPE}")"
    printf '"ssh_root":{"private_key_path":"%s","public_key_path":"%s","public_key":"%s","login_method":"key-only"},' \
        "$(json_escape "${KEY_FILE}")" \
        "$(json_escape "${KEY_FILE}.pub")" \
        "$(json_escape "${PUB_KEY}")"
    printf '"users":[{"user":"agflow","password":"%s","ssh_key_private_path":"%s","ssh_key_public_path":"%s","ssh_key_public":"%s","groups":%s,"sudo_nopasswd":true}],' \
        "$(json_escape "${AGFLOW_PASS}")" \
        "$(json_escape "${AGFLOW_KEY_FILE}")" \
        "$(json_escape "${AGFLOW_KEY_FILE}.pub")" \
        "$(json_escape "${AGFLOW_PUB_KEY}")" \
        "${MACHINE_GROUPS_JSON}"
    printf '"host":{"proxmox_host":"%s","created_at":"%s","script_version":"%s","conf_path":"%s","conf_backup_path":%s}' \
        "$(json_escape "${PROXMOX_HOST}")" \
        "${CREATED_AT}" \
        "$(json_escape "${SCRIPT_VERSION}")" \
        "$(json_escape "${CONF}")" \
        "$(json_str_or_null "${CONF_BACKUP_PATH}")"
    printf '}'
}

# ── Bloc docker (si --docker) ────────────────────────────────────────────────
build_docker_json() {
    local hello_bool
    hello_bool=$([ "${DOCKER_HELLO_OK}" -eq 1 ] && echo true || echo false)
    local live_restore_bool
    live_restore_bool=$([ "${LIVE_RESTORE}" = "1" ] && echo true || echo false)

    printf '{'
    printf '"docker_ok":%s,' "${DOCKER_OK}"
    printf '"docker_version":"%s","compose_version":"%s","hello_world_ok":%s,' \
        "$(json_escape "${docker_version}")" \
        "$(json_escape "${compose_version}")" \
        "${hello_bool}"
    printf '"live_restore":%s,' "${live_restore_bool}"
    printf '"address_pool":"%s","address_pool_size":%s,' \
        "$(json_escape "${DOCKER_ADDR_POOL}")" \
        "${DOCKER_ADDR_POOL_SIZE}"
    printf '"lxc_perms_added":true'
    printf '}'
}

# ── Bloc swarm (si --init-swarm OU --join-swarm) ─────────────────────────────
build_swarm_json() {
    local swarm_ready_bool="${SWARM_READY}"
    local force_used_bool
    force_used_bool=$([ "${FORCE}" -eq 1 ] && echo true || echo false)
    local force_leave_bool
    force_leave_bool=$([ "${FORCE_LEAVE}" = "yes" ] && echo true || echo false)
    local live_restore_was_bool
    live_restore_was_bool=$([ "${LIVE_RESTORE_ON}" = "yes" ] && echo true || echo false)
    local live_restore_fixed_bool
    live_restore_fixed_bool=$([ "${LIVE_RESTORE_FIXED}" -eq 1 ] && echo true || echo false)

    printf '{'

    if [ "${INIT_SWARM}" -eq 1 ]; then
        printf '"install":"init",'
    else
        printf '"install":"join",'
    fi

    printf '"swarm_ready":%s,' "${swarm_ready_bool}"
    printf '"tun_device_present":"%s",' "$(json_escape "${TUN_OK}")"
    printf '"kernel_modules_loaded":%s,' "${KERNEL_MODULES_LOADED}"
    printf '"docker_config":{"live_restore_was_on":%s,"live_restore_fixed":%s},' \
        "${live_restore_was_bool}" \
        "${live_restore_fixed_bool}"
    printf '"previous_state":{"swarm_state":"%s","force_used":%s,"force_leave_used":%s},' \
        "$(json_escape "${SWARM_PRE_STATE}")" \
        "${force_used_bool}" \
        "${force_leave_bool}"

    if [ "${INIT_SWARM}" -eq 1 ]; then
        # Tableau JSON des labels
        local labels_json="["
        if [ -n "${NODE_LABELS}" ]; then
            IFS=',' read -ra LABELS_FOR_JSON <<< "${NODE_LABELS}"
            local first=1
            for lbl in "${LABELS_FOR_JSON[@]}"; do
                [ -z "${lbl}" ] && continue
                [ ${first} -eq 1 ] || labels_json+=","
                labels_json+="\"$(json_escape "${lbl}")\""
                first=0
            done
        fi
        labels_json+="]"

        local join_worker_cmd="docker swarm join --token ${WORKER_TOKEN} ${ADVERTISE_ADDR_USED}:2377"
        local join_manager_cmd="docker swarm join --token ${MANAGER_TOKEN} ${ADVERTISE_ADDR_USED}:2377"

        printf '"manager":{"ip":"%s","port":2377,"node_id":%s,"labels":"%s","labels_list":%s},' \
            "$(json_escape "${ADVERTISE_ADDR_USED}")" \
            "$(json_str_or_null "${NODE_ID}")" \
            "$(json_escape "${NODE_LABELS}")" \
            "${labels_json}"
        printf '"pool":{"overlay":"%s","mask":%s},' \
            "$(json_escape "${POOL_OVERLAY}")" \
            "${POOL_MASK}"
        printf '"tokens":{"worker":"%s","manager":"%s","file":"%s"},' \
            "$(json_escape "${WORKER_TOKEN}")" \
            "$(json_escape "${MANAGER_TOKEN}")" \
            "$(json_escape "${TOKEN_FILE}")"
        printf '"join_commands":{"worker":"%s","manager":"%s"},' \
            "$(json_escape "${join_worker_cmd}")" \
            "$(json_escape "${join_manager_cmd}")"
        printf '"hostname":"%s"' \
            "$(json_escape "${NODE_HOSTNAME}")"
    else
        # join-swarm
        local as_manager_bool
        as_manager_bool=$([ "${JOIN_AS_MANAGER}" -eq 1 ] && echo true || echo false)

        printf '"node":{"id":"%s","role":"%s","state":"%s","advertise_addr":"%s","listen_addr":"%s"},' \
            "$(json_escape "${JOIN_NODE_ID}")" \
            "$(json_escape "${JOIN_NEW_ROLE}")" \
            "$(json_escape "${JOIN_NEW_STATE}")" \
            "$(json_escape "${ADVERTISE_ADDR_USED}")" \
            "$(json_escape "${LISTEN_ADDR_JOIN}")"
        printf '"target_manager":{"ip":"%s","port":2377},' \
            "$(json_escape "${JOIN_MANAGER_IP}")"
        printf '"joined_as":"%s","as_manager_requested":%s' \
            "$(json_escape "${JOIN_NEW_ROLE}")" \
            "${as_manager_bool}"
    fi

    printf '}'
}

# ── Composition finale ───────────────────────────────────────────────────────
printf '{'
printf '"status":"%s",' "${OVERALL_STATUS}"
printf '"exit_code":%s,' "${EXIT_CODE}"
printf '"machine":'
build_machine_json

if [ "${DOCKER_MODE}" -eq 1 ]; then
    printf ','
    printf '"docker":'
    build_docker_json
fi

if [ "${INIT_SWARM}" -eq 1 ] || [ "${JOIN_SWARM}" -eq 1 ]; then
    printf ','
    printf '"swarm":'
    build_swarm_json
fi

printf '}\n'

exit "${EXIT_CODE}"
