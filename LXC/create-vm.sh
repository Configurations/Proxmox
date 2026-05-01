#!/bin/bash
###############################################################################
# Script unifie : create-vm.sh
#
# A executer sur l'HOTE PROXMOX.
#
# Cree (ou reconfigure) une VM Proxmox a partir d'une image cloud-init Ubuntu,
# et optionnellement :
#   - installe Docker dans la VM                     (--docker)
#   - prepare la VM en "swarm-ready"                 (--swarm)
#   - initialise un nouveau cluster Docker Swarm     (--init-swarm)
#   - rejoint un cluster Swarm existant              (--join-swarm)
#
# Difference vs create-lxc.sh : la VM a son propre kernel, donc :
#   - pas de modules kernel a charger sur l'hote Proxmox
#   - pas de permissions LXC (apparmor / cgroup2 / mount) a configurer
#   - pas de bind /dev/net/tun (la VM en dispose nativement)
#   - "swarm-ready" se reduit a poser les sysctl reseau dans la VM + le tag
#
# Le bootstrap se fait via cloud-init : injection clef SSH root + config DHCP.
# Les etapes "interieur de la machine" se font via SSH (root) une fois la VM
# bootee et qemu-guest-agent operationnel.
#
# Flags :
#   --docker                  Installe Docker dans la VM
#   --swarm                   Prepare la VM swarm-ready (sysctl + tag)
#   --init-swarm              Init un cluster Swarm (implique --docker + --swarm)
#   --join-swarm              Rejoint un cluster (implique --docker + --swarm)
#       --manager-ip <IP>     IP du manager (obligatoire avec --join-swarm)
#       --token <TOKEN>       Token de join (obligatoire avec --join-swarm)
#       --as-manager          Rejoindre comme manager (defaut : worker)
#
# --init-swarm et --join-swarm sont mutuellement exclusifs.
# Sans aucun flag : VM nue (pas de Docker, pas de Swarm).
#
# Usage :
#   ./create-vm.sh <VMID> [hostname] [flags...]
#
# Exemples :
#   ./create-vm.sh 100 ag-test
#   ./create-vm.sh 101 ag-docker --docker
#   ./create-vm.sh 102 ag-mgr --init-swarm
#   ./create-vm.sh 103 ag-worker --join-swarm --manager-ip 192.168.10.115 \
#                                --token SWMTKN-1-xxx
#   STORAGE=local-lvm DISK_SIZE=50 ./create-vm.sh 104 ag-data --init-swarm
#
# Variables d'environnement :
#   STORAGE=auto          Selection auto du storage (defaut)
#   DISK_SIZE=30          Taille disque en GB
#   CORES=4               Nombre de coeurs
#   MEMORY=8192           RAM en MB
#   BRIDGE=vmbr0          Bridge reseau
#   SAFETY_MARGIN_GB=5    Marge libre minimale dans le pool
#   SSH_KEY_DIR=...       Dossier des clefs SSH (defaut /root/.ssh/vm-keys)
#   CLOUD_IMG_DIR=...     Dossier des images cloud (defaut /var/lib/vz/template/iso)
#   CLOUD_IMG_NAME=...    Nom du fichier image (defaut Ubuntu 24.04)
#   CLOUD_IMG_URL=...     URL de telechargement si image absente
#   LIVE_RESTORE=0        Docker live-restore (0=false, compatible Swarm)
#   DOCKER_ADDR_POOL=172.30.0.0/16
#   DOCKER_ADDR_POOL_SIZE=24
#   POOL_OVERLAY=10.20.0.0/16        Pool overlay Swarm (init-swarm)
#   POOL_MASK=24
#   NODE_LABELS="role=control,tenant=agflow"
#   ADVERTISE_ADDR=<ip>              Force IP advertise Swarm
#   FORCE=1                          Reinit Swarm meme si actif (DESTRUCTIF)
#   FORCE_LEAVE=yes                  Quitte le Swarm courant avant join
#   AUTO_FIX=1                       Correction auto live-restore
#   TOKEN_DIR=...                    Dossier des tokens Swarm
#   MIN_FREE_MB=1024                 Espace min dans la VM (Docker)
#   SSH_BOOT_TIMEOUT=180             Timeout d'attente SSH apres boot (sec)
#
# Pre-requis : qemu-guest-agent doit etre demarre dans la VM (cloud-image
# Ubuntu = oui par defaut). Le paquet wget est present sur l'hote pour
# telecharger l'image cloud si elle est absente.
###############################################################################
set -uo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Helpers JSON + fail
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
DISK_SIZE="${DISK_SIZE:-30}"
STORAGE="${STORAGE:-auto}"
BRIDGE="${BRIDGE:-vmbr0}"
SSH_KEY_DIR="${SSH_KEY_DIR:-/root/.ssh/vm-keys}"
SAFETY_MARGIN_GB="${SAFETY_MARGIN_GB:-5}"
SSH_BOOT_TIMEOUT="${SSH_BOOT_TIMEOUT:-180}"

# Image cloud-init (Ubuntu 24.04 server)
CLOUD_IMG_DIR="${CLOUD_IMG_DIR:-/var/lib/vz/template/iso}"
CLOUD_IMG_NAME="${CLOUD_IMG_NAME:-ubuntu-24.04-server-cloudimg-amd64.img}"
CLOUD_IMG_URL="${CLOUD_IMG_URL:-https://cloud-images.ubuntu.com/releases/24.04/release/${CLOUD_IMG_NAME}}"

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
TOKEN_DIR="${TOKEN_DIR:-/root/.ssh/vm-keys}"
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
LIVE_RESTORE_FIXED=0
LIVE_RESTORE_ON="no"
SWARM_PRE_STATE="inactive"
NODE_ID=""
WORKER_TOKEN=""
MANAGER_TOKEN=""
TOKEN_FILE=""
JOIN_NEW_STATE=""
JOIN_NEW_ROLE=""
JOIN_NODE_ID=""
ADVERTISE_ADDR_USED=""
VM_IP=""
VM_DISTRO=""
CLOUD_IMG_DOWNLOADED=0

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

if [ "${INIT_SWARM}" -eq 1 ] || [ "${JOIN_SWARM}" -eq 1 ]; then
    DOCKER_MODE=1
    SWARM_MODE=1
fi

if [ "${INIT_SWARM}" -eq 1 ] && [ "${JOIN_SWARM}" -eq 1 ]; then
    fail "--init-swarm et --join-swarm sont mutuellement exclusifs"
fi

if [ "${JOIN_SWARM}" -eq 1 ]; then
    if [ -z "${JOIN_MANAGER_IP}" ] || [ -z "${JOIN_TOKEN}" ]; then
        fail "--join-swarm requiert --manager-ip <IP> et --token <TOKEN>"
    fi
fi

VMID="${1:-}"
VM_NAME_RAW="${2:-agflow-vm}"
VM_NAME=$(echo "${VM_NAME_RAW}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

if [ -z "${VMID}" ]; then
    cat << 'USAGE'
Usage : ./create-vm.sh <VMID> [hostname] [flags...]

Flags :
  --docker                  Installe Docker dans la VM
  --swarm                   Prepare la VM swarm-ready (sysctl + tag)
  --init-swarm              Init un cluster Swarm (implique --docker + --swarm)
  --join-swarm              Rejoint un cluster (implique --docker + --swarm)
      --manager-ip <IP>     IP du manager (obligatoire avec --join-swarm)
      --token <TOKEN>       Token de join (obligatoire avec --join-swarm)
      --as-manager          Rejoindre comme manager (defaut : worker)

Sans flag : VM nue (pas de Docker, pas de Swarm).

VMs existantes :
USAGE
    qm list 2>/dev/null || true
    exit 1
fi

CONF="/etc/pve/qemu-server/${VMID}.conf"
ROOT_VM_PASS=$(tr -dc 'A-Za-z0-9_!@#$%^&*' </dev/urandom 2>/dev/null | head -c 24 || echo "vmpass$(date +%s)")

# ══════════════════════════════════════════════════════════════════════════════
# TABLEAU DE BORD STORAGES + SELECTION AUTOMATIQUE
# ══════════════════════════════════════════════════════════════════════════════
# Pour les VMs, on cherche les storages qui supportent le content-type "images".

show_storage_dashboard() {
    echo "==========================================="
    echo "  Etat des storages Proxmox (content=images)"
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
        local supports_images="no"
        if [ "${type}" = "lvmthin" ] || [ "${type}" = "zfspool" ]; then
            supports_images="yes"
        elif echo "${content}" | grep -q "images"; then
            supports_images="yes"
        fi

        local marker=""
        if [ "${supports_images}" = "no" ]; then
            marker="(no images)"
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
        local supports_images="no"
        if [ "${type}" = "lvmthin" ] || [ "${type}" = "zfspool" ]; then
            supports_images="yes"
        elif echo "${content}" | grep -q "images"; then
            supports_images="yes"
        fi
        [ "${supports_images}" != "yes" ] && continue

        echo "${avail_kb} ${name}"
    done | sort -rn | head -1 | awk '{print $2}'
}

check_storage_has_space() {
    local storage_name="$1"
    local needed_gb="$2"

    local line
    line=$(pvesm status 2>/dev/null | awk -v s="${storage_name}" '$1==s {print}' | head -1)

    if [ -z "${line}" ]; then
        echo "ERREUR : storage '${storage_name}' introuvable"
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
        echo "         Requis     : ${needed_gb} GB + ${SAFETY_MARGIN_GB} GB de marge"
        return 1
    fi

    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Detection mode : CREATION ou RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
if qm status "${VMID}" &>/dev/null; then
    MODE="reconfigure"
else
    MODE="create"
fi

# Resoudre STORAGE=auto et verifier l'espace (mode CREATION uniquement)
if [ "${MODE}" = "create" ]; then
    show_storage_dashboard

    if [ "${STORAGE}" = "auto" ]; then
        echo "  STORAGE=auto -> selection automatique..."
        STORAGE=$(auto_select_storage)
        if [ -z "${STORAGE}" ]; then
            fail "Aucun storage actif compatible 'images' trouve."
        fi
        echo "  -> Storage selectionne : ${STORAGE}"
        echo ""
    fi

    echo "  Verification de l'espace sur ${STORAGE} (besoin : ${DISK_SIZE} GB + ${SAFETY_MARGIN_GB} GB de marge)..."
    if ! check_storage_has_space "${STORAGE}" "${DISK_SIZE}"; then
        echo ""
        BEST_STORAGE=$(auto_select_storage)
        if [ -n "${BEST_STORAGE}" ] && [ "${BEST_STORAGE}" != "${STORAGE}" ]; then
            echo "     STORAGE=${BEST_STORAGE} $0 ${VMID} ${VM_NAME_RAW}"
        fi
        exit 1
    fi
    echo "  -> OK"
    echo ""
fi

echo "==========================================="
if [ "${MODE}" = "create" ]; then
    echo "  VM ${VMID} inexistante -> CREATION"
else
    echo "  VM ${VMID} detectee -> RECONFIGURATION"
fi
[ "${DOCKER_MODE}" -eq 1 ] && echo "  Docker     : ACTIVE"
[ "${SWARM_MODE}" -eq 1 ] && echo "  Swarm-ready: ACTIVE"
[ "${INIT_SWARM}" -eq 1 ] && echo "  Init-Swarm : ACTIVE"
[ "${JOIN_SWARM}" -eq 1 ] && echo "  Join-Swarm : ACTIVE (manager=${JOIN_MANAGER_IP})"
echo "==========================================="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# Tags / description
# ══════════════════════════════════════════════════════════════════════════════
build_tags() {
    local tags="agflow"
    [ "${DOCKER_MODE}" -eq 1 ] && tags="${tags},docker"
    [ "${SWARM_MODE}" -eq 1 ] && tags="${tags},swarm-ready"
    echo "${tags}"
}

build_description() {
    if [ "${DOCKER_MODE}" -eq 1 ] && [ "${SWARM_MODE}" -eq 1 ]; then
        echo "agflow.docker platform (Swarm node)"
    elif [ "${DOCKER_MODE}" -eq 1 ]; then
        echo "agflow.docker platform"
    elif [ "${SWARM_MODE}" -eq 1 ]; then
        echo "agflow VM (Swarm node)"
    else
        echo "agflow VM"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Generation clef SSH root (avant creation : injectee via cloud-init)
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "${SSH_KEY_DIR}"
KEY_FILE="${SSH_KEY_DIR}/id_ed25519_vm${VMID}"
if [ -f "${KEY_FILE}" ]; then
    echo "  Clef SSH existante : ${KEY_FILE}"
else
    echo "  Generation de la clef SSH root..."
    ssh-keygen -t ed25519 -f "${KEY_FILE}" -N "" -C "proxmox-host->vm-${VMID}" -q
    echo "  -> Clef generee : ${KEY_FILE}"
fi
PUB_KEY=$(cat "${KEY_FILE}.pub")

# ══════════════════════════════════════════════════════════════════════════════
# MODE CREATION
# ══════════════════════════════════════════════════════════════════════════════
if [ "${MODE}" = "create" ]; then

    # ── Cloud image : verifier presence, telecharger sinon ──────────────────
    CLOUD_IMG_PATH="${CLOUD_IMG_DIR}/${CLOUD_IMG_NAME}"
    if [ ! -f "${CLOUD_IMG_PATH}" ]; then
        echo "[1/5] Telechargement de l'image cloud Ubuntu..."
        mkdir -p "${CLOUD_IMG_DIR}"
        if wget -q --show-progress -O "${CLOUD_IMG_PATH}" "${CLOUD_IMG_URL}"; then
            echo "  -> Telechargee : ${CLOUD_IMG_PATH}"
            CLOUD_IMG_DOWNLOADED=1
        else
            rm -f "${CLOUD_IMG_PATH}"
            fail "Echec du telechargement de l'image cloud" \
                 "URL : ${CLOUD_IMG_URL}"
        fi
    else
        echo "[1/5] Image cloud presente : ${CLOUD_IMG_PATH}"
    fi

    VM_TAGS=$(build_tags)
    VM_DESCRIPTION=$(build_description)

    echo ""
    echo "  VM ID    : ${VMID}"
    echo "  Nom      : ${VM_NAME}"
    echo "  CPU      : ${CORES} coeurs"
    echo "  RAM      : ${MEMORY} MB"
    echo "  Disque   : ${DISK_SIZE}G"
    echo "  Storage  : ${STORAGE}"
    echo "  Reseau   : ${BRIDGE}"
    echo "  Image    : ${CLOUD_IMG_NAME}"
    echo "  Tags     : ${VM_TAGS}"
    echo ""

    # ── qm create : VM minimale ─────────────────────────────────────────────
    echo "[2/5] Creation de la VM..."
    qm create "${VMID}" \
        --name "${VM_NAME}" \
        --cores "${CORES}" \
        --sockets 1 \
        --memory "${MEMORY}" \
        --balloon 0 \
        --net0 "virtio,bridge=${BRIDGE}" \
        --agent "enabled=1,fstrim_cloned_disks=1" \
        --ostype l26 \
        --cpu cputype=host \
        --tags "${VM_TAGS}" \
        --description "${VM_DESCRIPTION}"
    echo "  -> VM creee"

    # ── Importdisk + boot ───────────────────────────────────────────────────
    echo "[3/5] Import du disque cloud + configuration boot..."
    qm importdisk "${VMID}" "${CLOUD_IMG_PATH}" "${STORAGE}" >/dev/null
    qm set "${VMID}" --scsihw virtio-scsi-single >/dev/null
    qm set "${VMID}" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,iothread=1" >/dev/null
    qm resize "${VMID}" scsi0 "${DISK_SIZE}G" >/dev/null
    qm set "${VMID}" --boot "order=scsi0" >/dev/null
    echo "  -> Disque importe + boot configure"

    # ── Cloud-init : user, ssh, network ─────────────────────────────────────
    echo "[4/5] Configuration cloud-init..."
    qm set "${VMID}" --ide2 "${STORAGE}:cloudinit" >/dev/null
    qm set "${VMID}" --serial0 socket --vga serial0 >/dev/null
    qm set "${VMID}" --ciuser root >/dev/null
    qm set "${VMID}" --cipassword "${ROOT_VM_PASS}" >/dev/null
    qm set "${VMID}" --sshkeys "${KEY_FILE}.pub" >/dev/null
    qm set "${VMID}" --ipconfig0 "ip=dhcp" >/dev/null
    qm set "${VMID}" --nameserver "8.8.8.8" >/dev/null
    qm set "${VMID}" --searchdomain "1.1.1.1" >/dev/null
    echo "  -> Cloud-init configure (user=root, dhcp, clef SSH injectee)"

    STEP_BOOT=5
    STEP_TOTAL=5

# ══════════════════════════════════════════════════════════════════════════════
# MODE RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
else

    echo "[1/3] Backup de la configuration..."
    CONF_BACKUP_PATH="${CONF}.backup.$(date +%Y%m%d%H%M%S)"
    cp "${CONF}" "${CONF_BACKUP_PATH}"
    echo "  -> Backup : ${CONF_BACKUP_PATH}"

    echo "[2/3] Mise a jour des tags / description..."
    EXISTING_TAGS=$(grep "^tags:" "${CONF}" 2>/dev/null | head -1 | sed 's/^tags: //' || echo "")

    NEW_TAGS="${EXISTING_TAGS}"
    if [ "${DOCKER_MODE}" -eq 1 ] && ! echo "${NEW_TAGS}" | grep -q "docker"; then
        [ -z "${NEW_TAGS}" ] && NEW_TAGS="agflow;docker" || NEW_TAGS="${NEW_TAGS};docker"
    fi
    if [ "${SWARM_MODE}" -eq 1 ] && ! echo "${NEW_TAGS}" | grep -q "swarm-ready"; then
        [ -z "${NEW_TAGS}" ] && NEW_TAGS="agflow;swarm-ready" || NEW_TAGS="${NEW_TAGS};swarm-ready"
    fi
    [ -z "${NEW_TAGS}" ] && NEW_TAGS="agflow"

    NEW_TAGS_COMMA=$(echo "${NEW_TAGS}" | tr ';' ',')
    qm set "${VMID}" --tags "${NEW_TAGS_COMMA}" >/dev/null
    qm set "${VMID}" --description "$(build_description)" >/dev/null
    echo "  -> Tags : ${NEW_TAGS_COMMA}"

    # S'assurer que la clef SSH cloud-init est a jour si la VM est arretee
    if ! qm status "${VMID}" 2>/dev/null | grep -q running; then
        qm set "${VMID}" --sshkeys "${KEY_FILE}.pub" >/dev/null 2>&1 || true
    fi

    STEP_BOOT=3
    STEP_TOTAL=3
fi

# ══════════════════════════════════════════════════════════════════════════════
# COMMUN : Demarrage + attente guest agent + IP
# ══════════════════════════════════════════════════════════════════════════════

echo "[${STEP_BOOT}/${STEP_TOTAL}] Demarrage de la VM..."
if qm status "${VMID}" 2>/dev/null | grep -q running; then
    echo "  -> VM deja demarree"
else
    qm start "${VMID}"
    echo "  -> VM demarree"
fi

# ── Attente qemu-guest-agent ────────────────────────────────────────────────
echo ""
echo "  Attente de qemu-guest-agent..."
elapsed=0
while [ ${elapsed} -lt 180 ]; do
    if qm guest ping "${VMID}" 2>/dev/null; then
        echo "  -> Guest agent operationnel (${elapsed}s)"
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
if [ ${elapsed} -ge 180 ]; then
    fail "qemu-guest-agent n'a pas demarre dans la VM (timeout 180s)" \
         "Cloud-init ne s'est peut-etre pas execute. Verifiez : qm terminal ${VMID}"
fi

# ── Recuperation IP via guest agent ─────────────────────────────────────────
echo ""
echo "  Recuperation de l'IP via guest agent..."
elapsed=0
while [ ${elapsed} -lt 120 ]; do
    VM_IP=$(qm guest cmd "${VMID}" network-get-interfaces 2>/dev/null \
            | grep -oP '"ip-address"\s*:\s*"\K[0-9.]+(?=")' \
            | grep -v '^127\.' \
            | grep -v '^169\.254\.' \
            | head -1 || echo "")
    if [ -n "${VM_IP}" ]; then
        echo "  -> IP : ${VM_IP} (${elapsed}s)"
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
if [ -z "${VM_IP}" ]; then
    fail "Impossible de recuperer l'IP de la VM via guest agent" \
         "Verifiez la conf reseau : qm guest cmd ${VMID} network-get-interfaces"
fi

# ── Attente SSH ─────────────────────────────────────────────────────────────
echo ""
echo "  Attente de SSH..."
SSH_OPTS=(-i "${KEY_FILE}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)

elapsed=0
while [ ${elapsed} -lt "${SSH_BOOT_TIMEOUT}" ]; do
    if ssh "${SSH_OPTS[@]}" "root@${VM_IP}" true 2>/dev/null; then
        echo "  -> SSH operationnel (${elapsed}s)"
        break
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
if [ ${elapsed} -ge "${SSH_BOOT_TIMEOUT}" ]; then
    fail "SSH n'a pas repondu dans le delai (${SSH_BOOT_TIMEOUT}s)" \
         "Cloud-init n'a peut-etre pas injecte la clef. Verifiez : qm terminal ${VMID}"
fi

# ── Helpers SSH ─────────────────────────────────────────────────────────────
vm_exec() {
    ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "$@"
}

vm_push() {
    scp "${SSH_OPTS[@]}" "$1" "root@${VM_IP}:$2"
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMUN : apt update + paquets de base + agflow user
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "  Mise a jour et installation des paquets de base..."

# Note : cloud-init a deja injecte la clef root; on ne refait pas la conf SSH.
# On passe le bloc apt-get + base tools en heredoc 'EOF' (pas d'interpolation).
APT_BASE_TMP="$(mktemp /tmp/apt-base.XXXXXX.sh)"
cat > "${APT_BASE_TMP}" << 'APT_BASE_EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

apt-get update -qq
apt-get "${APT_OPTS[@]}" upgrade -y -qq

apt-get "${APT_OPTS[@]}" install -y -qq \
  curl wget git vim htop tmux \
  ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv \
  unattended-upgrades apt-listchanges

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UATEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UATEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'PERIODEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
PERIODEOF

systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl restart unattended-upgrades >/dev/null 2>&1 || true
echo "  -> Paquets de base + unattended-upgrades configures"
APT_BASE_EOF

vm_push "${APT_BASE_TMP}" /root/apt-base.sh
vm_exec "chmod +x /root/apt-base.sh && /root/apt-base.sh"
rm -f "${APT_BASE_TMP}"

# ── Sysctl swarm dans la VM (si --swarm) ────────────────────────────────────
if [ "${SWARM_MODE}" -eq 1 ]; then
    echo ""
    echo "  Configuration sysctl Swarm dans la VM..."
    vm_exec bash -c "'cat > /etc/sysctl.d/99-swarm.conf << SYSEOF
# Forwarding IP requis pour Docker et overlay networks Swarm
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1

# Conntrack pour les overlay networks
net.netfilter.nf_conntrack_max=131072

# Buffers UDP plus larges (VXLAN encapsule en UDP/4789)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
SYSEOF
modprobe br_netfilter 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || true
echo \"  -> /etc/sysctl.d/99-swarm.conf cree et applique\"'"
fi

# ── Creer l'utilisateur agflow ──────────────────────────────────────────────
echo ""
echo "  Creation de l'utilisateur agflow..."

AGFLOW_PASS=$(tr -dc 'A-Za-z0-9_!@#$%^&*' </dev/urandom 2>/dev/null | head -c 24 || echo "agflow$(date +%s)")

AGFLOW_KEY_FILE="${SSH_KEY_DIR}/id_ed25519_agflow_vm${VMID}"
if [ ! -f "${AGFLOW_KEY_FILE}" ]; then
    ssh-keygen -t ed25519 -f "${AGFLOW_KEY_FILE}" -N "" -C "agflow@vm-${VMID}" -q
    echo "  -> Clef agflow generee : ${AGFLOW_KEY_FILE}"
else
    echo "  -> Clef agflow existante : ${AGFLOW_KEY_FILE}"
fi
AGFLOW_PUB_KEY=$(cat "${AGFLOW_KEY_FILE}.pub")

AGFLOW_GROUPS_CMD="sudo"
[ "${DOCKER_MODE}" -eq 1 ] && AGFLOW_GROUPS_CMD="sudo,docker"

# Heredoc non-interpole pour eviter les soucis d'echappement
AGFLOW_TMP="$(mktemp /tmp/agflow.XXXXXX.sh)"
cat > "${AGFLOW_TMP}" << AGFLOW_EOF
#!/bin/bash
set -euo pipefail

if ! id agflow &>/dev/null; then
    useradd -m -s /bin/bash -G ${AGFLOW_GROUPS_CMD} agflow 2>/dev/null || useradd -m -s /bin/bash agflow
    echo "  -> Utilisateur agflow cree"
else
    echo "  -> Utilisateur agflow existant"
    for grp in \$(echo '${AGFLOW_GROUPS_CMD}' | tr ',' ' '); do
        getent group "\${grp}" >/dev/null 2>&1 && usermod -aG "\${grp}" agflow 2>/dev/null || true
    done
fi

echo 'agflow:${AGFLOW_PASS}' | chpasswd

mkdir -p /home/agflow/.ssh
chmod 700 /home/agflow/.ssh

if ! grep -qF '${AGFLOW_PUB_KEY}' /home/agflow/.ssh/authorized_keys 2>/dev/null; then
    echo '${AGFLOW_PUB_KEY}' >> /home/agflow/.ssh/authorized_keys
fi
chmod 600 /home/agflow/.ssh/authorized_keys
chown -R agflow:agflow /home/agflow/.ssh

echo 'agflow ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agflow
chmod 440 /etc/sudoers.d/agflow
echo "  -> sudo NOPASSWD configure"
AGFLOW_EOF

vm_push "${AGFLOW_TMP}" /root/setup-agflow.sh
vm_exec "chmod +x /root/setup-agflow.sh && /root/setup-agflow.sh"
rm -f "${AGFLOW_TMP}"

# ══════════════════════════════════════════════════════════════════════════════
# INSTALLATION DOCKER (si --docker)
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

free_mb=$(df --output=avail -BM / | tail -1 | tr -d 'M ')
if [ "${free_mb}" -lt "${MIN_FREE_MB}" ]; then
    echo "ERREUR : espace disque insuffisant (${free_mb} MB libre, ${MIN_FREE_MB} MB requis)"
    exit 1
fi
echo "  -> Espace disque libre : ${free_mb} MB (OK)"

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

apt-get clean
apt-get autoremove -y -qq 2>/dev/null || true
DOCKER_INSTALL_EOF

    vm_push "${DOCKER_INSTALL_TMP}" /root/install-docker.sh
    vm_exec "chmod +x /root/install-docker.sh"

    if vm_exec env \
        MIN_FREE_MB="${MIN_FREE_MB}" \
        LIVE_RESTORE_VAL="${LIVE_RESTORE_VAL}" \
        DOCKER_ADDR_POOL="${DOCKER_ADDR_POOL}" \
        DOCKER_ADDR_POOL_SIZE="${DOCKER_ADDR_POOL_SIZE}" \
        /root/install-docker.sh; then
        DOCKER_INSTALL_OK=1
    else
        DOCKER_INSTALL_OK=0
        echo "  [!] L'installation Docker a echoue"
    fi

    rm -f "${DOCKER_INSTALL_TMP}"

    # ── Verification ────────────────────────────────────────────────────────
    echo ""
    echo "  Verification post-installation Docker..."

    if vm_exec "command -v docker >/dev/null && docker info >/dev/null 2>&1"; then
        DOCKER_OK=1
        echo "  -> Docker daemon : OK (operationnel)"

        if vm_exec "docker run --rm hello-world >/dev/null 2>&1"; then
            DOCKER_HELLO_OK=1
            echo "  -> Docker run    : OK (test hello-world reussi)"
        else
            DOCKER_HELLO_OK=0
            echo "  -> Docker run    : ECHEC"
        fi
    else
        DOCKER_OK=0
        echo "  -> ERREUR : Docker n'est pas operationnel."
    fi

    # Pour les VMs, swarm-ready ne depend que de Docker (pas de /dev/net/tun bind)
    if [ "${SWARM_MODE}" -eq 1 ] && [ "${DOCKER_OK}" -eq 1 ]; then
        SWARM_READY="true"
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

    if [ "${DOCKER_OK}" -ne 1 ]; then
        fail "Docker n'est pas operationnel, impossible d'initialiser Swarm"
    fi

    SWARM_PRE_STATE=$(vm_exec "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null || echo "unknown")

    if [ "${SWARM_PRE_STATE}" = "active" ]; then
        if [ "${FORCE}" -eq 1 ]; then
            echo "  -> Swarm deja actif, FORCE=1 : leave force..."
            vm_exec "docker swarm leave --force" >/dev/null 2>&1 || true
            echo "  -> Swarm reinitialise"
        else
            echo "  -> Swarm deja actif sur cette VM."
            vm_exec "docker node ls" 2>/dev/null | sed 's/^/    /' || true
            echo "  Pour reinitialiser : FORCE=1 $0 ${VMID}"
            INIT_SWARM_OK=2
        fi
    fi

    if [ "${INIT_SWARM_OK}" -ne 2 ]; then
        echo ""
        echo "  Verification live-restore..."
        LIVE_RESTORE_ON=$(vm_exec "[ -f /etc/docker/daemon.json ] && grep -q '\"live-restore\"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json && echo yes || echo no" 2>/dev/null || echo "no")

        if [ "${LIVE_RESTORE_ON}" = "yes" ]; then
            if [ "${AUTO_FIX}" -eq 1 ]; then
                echo "  -> live-restore=true detecte, correction..."
                vm_exec "sed -i 's/\"live-restore\":[[:space:]]*true/\"live-restore\": false/' /etc/docker/daemon.json && (systemctl reload docker 2>/dev/null || systemctl restart docker)" \
                    || fail "Impossible de corriger live-restore"
                sleep 2
                LIVE_RESTORE_FIXED=1
                echo "  -> live-restore : false (compatible Swarm)"
            else
                fail "live-restore=true detecte" "Relancez avec AUTO_FIX=1"
            fi
        else
            echo "  -> live-restore : false (compatible Swarm) : OK"
        fi

        # IP advertise : par defaut l'IP de la VM
        if [ -n "${ADVERTISE_ADDR:-}" ]; then
            echo "  -> IP forcee via env : ${ADVERTISE_ADDR}"
        else
            ADVERTISE_ADDR="${VM_IP}"
            echo "  -> IP detectee : ${ADVERTISE_ADDR}"
        fi
        ADVERTISE_ADDR_USED="${ADVERTISE_ADDR}"

        POOL_PREFIX=$(echo "${POOL_OVERLAY}" | cut -d. -f1-2)
        ADV_PREFIX=$(echo "${ADVERTISE_ADDR}" | cut -d. -f1-2)
        if [ "${POOL_PREFIX}" = "${ADV_PREFIX}" ]; then
            echo "  -> ATTENTION : pool overlay (${POOL_OVERLAY}) chevauche le subnet de la VM (${ADVERTISE_ADDR})"
        fi

        echo "  -> Initialisation Swarm..."
        INIT_OUTPUT=$(vm_exec "docker swarm init \
            --advertise-addr ${ADVERTISE_ADDR} \
            --listen-addr ${ADVERTISE_ADDR}:2377 \
            --default-addr-pool ${POOL_OVERLAY} \
            --default-addr-pool-mask-length ${POOL_MASK}" 2>&1)
        INIT_RC=$?

        if [ ${INIT_RC} -ne 0 ]; then
            echo "  ECHEC docker swarm init :"
            echo "${INIT_OUTPUT}" | sed 's/^/    /'
            fail "Initialisation Swarm echouee"
        fi
        echo "  -> Swarm initialise"

        WORKER_TOKEN=$(vm_exec "docker swarm join-token worker -q" 2>/dev/null | tr -d '\r\n')
        MANAGER_TOKEN=$(vm_exec "docker swarm join-token manager -q" 2>/dev/null | tr -d '\r\n')

        if [ -z "${WORKER_TOKEN}" ] || [ -z "${MANAGER_TOKEN}" ]; then
            fail "Impossible de recuperer les tokens"
        fi

        mkdir -p "${TOKEN_DIR}"
        TOKEN_FILE="${TOKEN_DIR}/swarm-tokens-vm${VMID}.json"
        cat > "${TOKEN_FILE}" << EOF
{
  "manager_vmid": "${VMID}",
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

        NODE_ID=$(vm_exec "docker node ls --format '{{.ID}}'" 2>/dev/null | head -1 | tr -d '\r\n')
        if [ -n "${NODE_ID}" ] && [ -n "${NODE_LABELS}" ]; then
            IFS=',' read -ra LABELS_ARRAY <<< "${NODE_LABELS}"
            LABEL_ARGS=""
            for lbl in "${LABELS_ARRAY[@]}"; do
                LABEL_ARGS="${LABEL_ARGS} --label-add ${lbl}"
            done
            vm_exec "docker node update ${LABEL_ARGS} ${NODE_ID}" >/dev/null 2>&1 || \
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

    if [ -z "${ADVERTISE_ADDR_USED}" ]; then
        if [ -n "${ADVERTISE_ADDR:-}" ]; then
            ADVERTISE_ADDR_USED="${ADVERTISE_ADDR}"
        else
            ADVERTISE_ADDR_USED="${VM_IP}"
        fi
    fi

    echo "  Manager IP : ${JOIN_MANAGER_IP}:2377"
    echo "  Role       : ${JOIN_ROLE}"
    echo "  Advertise  : ${ADVERTISE_ADDR_USED}"
    echo "  Listen     : ${LISTEN_ADDR_JOIN}"

    SWARM_PRE_STATE=$(vm_exec "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null || echo "unknown")
    if [ "${SWARM_PRE_STATE}" = "active" ]; then
        if [ "${FORCE_LEAVE}" = "yes" ]; then
            echo "  -> Swarm deja actif, FORCE_LEAVE=yes : leave force..."
            vm_exec "docker swarm leave --force" >/dev/null 2>&1 || true
            sleep 2
        else
            fail "VM ${VMID} deja dans un Swarm actif" "Relancez avec FORCE_LEAVE=yes"
        fi
    fi

    echo "  Test de connectivite vers ${JOIN_MANAGER_IP}:2377..."
    if vm_exec "timeout 5 bash -c '</dev/tcp/${JOIN_MANAGER_IP}/2377' 2>/dev/null"; then
        echo "  -> Manager joignable"
    else
        fail "Impossible de joindre ${JOIN_MANAGER_IP}:2377"
    fi

    echo "  -> Rejoindre comme ${JOIN_ROLE}..."
    JOIN_OUTPUT=$(vm_exec "docker swarm join \
        --advertise-addr ${ADVERTISE_ADDR_USED} \
        --listen-addr ${LISTEN_ADDR_JOIN} \
        --token ${JOIN_TOKEN} \
        ${JOIN_MANAGER_IP}:2377" 2>&1)
    JOIN_RC=$?

    if [ ${JOIN_RC} -ne 0 ]; then
        echo "  Sortie : ${JOIN_OUTPUT}"
        fail "Echec du join Swarm" "Token, IP manager, ou role incorrect"
    fi
    echo "  -> ${JOIN_OUTPUT}"

    sleep 3
    JOIN_NEW_STATE=$(vm_exec "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null | tr -d '\r\n' || echo "unknown")
    JOIN_NEW_ROLE=$(vm_exec "docker info --format '{{if .Swarm.ControlAvailable}}manager{{else}}worker{{end}}'" 2>/dev/null | tr -d '\r\n' || echo "unknown")
    JOIN_NODE_ID=$(vm_exec "docker info --format '{{.Swarm.NodeID}}'" 2>/dev/null | tr -d '\r\n' || echo "")

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
VM_DISTRO=$(vm_exec "if [ -f /etc/os-release ]; then . /etc/os-release; echo \"\${NAME} \${VERSION_ID}\"; else echo unknown; fi" 2>/dev/null | tr -d '\r\n' || echo "unknown")
NODE_HOSTNAME=$(vm_exec "hostname" 2>/dev/null | tr -d '\r\n' || echo "")

if [ "${DOCKER_MODE}" -eq 1 ]; then
    docker_version=$(vm_exec "docker --version" 2>/dev/null | tr -d '\r\n' || echo "non installe")
    compose_version=$(vm_exec "docker compose version" 2>/dev/null | tr -d '\r\n' || echo "non installe")
else
    docker_version=""
    compose_version=""
fi

# ══════════════════════════════════════════════════════════════════════════════
# Resume final
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==========================================="
echo "  VM ${VMID} : ${MODE^^} terminee"
echo "==========================================="
echo "  Distribution : ${VM_DISTRO}"
echo "  IP           : ${VM_IP}"
echo "  Acces        : ssh -i ${KEY_FILE} root@${VM_IP}"
echo ""
echo "  agflow user  : ${AGFLOW_PASS}"
echo "                 ssh -i ${AGFLOW_KEY_FILE} agflow@${VM_IP}"
echo "  root pass    : ${ROOT_VM_PASS} (cloud-init, pour console)"
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

MACHINE_GROUPS_JSON='["sudo"]'
if [ "${DOCKER_MODE}" -eq 1 ]; then
    MACHINE_GROUPS_JSON='["sudo","docker"]'
fi

build_machine_json() {
    printf '{'
    printf '"type":"vm",'
    printf '"vmid":"%s","hostname":"%s","hostname_raw":"%s",' \
        "$(json_escape "${VMID}")" \
        "$(json_escape "${VM_NAME}")" \
        "$(json_escape "${VM_NAME_RAW}")"
    printf '"mode":"%s",' "${MODE}"
    printf '"ressources":{"cores":%s,"memory":%s,"disk_size":%s,"storage":"%s","bridge":"%s"},' \
        "${CORES}" "${MEMORY}" "${DISK_SIZE}" \
        "$(json_escape "${STORAGE}")" \
        "$(json_escape "${BRIDGE}")"
    printf '"systeme":{"distro":"%s","ip":"%s","ip_type":"dhcp"},' \
        "$(json_escape "${VM_DISTRO}")" \
        "$(json_escape "${VM_IP}")"
    printf '"cloud_init":{"image_name":"%s","image_path":"%s","image_downloaded":%s,"ciuser":"root","ipconfig":"dhcp"},' \
        "$(json_escape "${CLOUD_IMG_NAME}")" \
        "$(json_escape "${CLOUD_IMG_DIR}/${CLOUD_IMG_NAME}")" \
        "$([ "${CLOUD_IMG_DOWNLOADED}" -eq 1 ] && echo true || echo false)"
    printf '"ssh_root":{"private_key_path":"%s","public_key_path":"%s","public_key":"%s","login_method":"key-only","root_password":"%s"},' \
        "$(json_escape "${KEY_FILE}")" \
        "$(json_escape "${KEY_FILE}.pub")" \
        "$(json_escape "${PUB_KEY}")" \
        "$(json_escape "${ROOT_VM_PASS}")"
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
    printf '"address_pool":"%s","address_pool_size":%s' \
        "$(json_escape "${DOCKER_ADDR_POOL}")" \
        "${DOCKER_ADDR_POOL_SIZE}"
    printf '}'
}

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
    printf '"docker_config":{"live_restore_was_on":%s,"live_restore_fixed":%s},' \
        "${live_restore_was_bool}" \
        "${live_restore_fixed_bool}"
    printf '"previous_state":{"swarm_state":"%s","force_used":%s,"force_leave_used":%s},' \
        "$(json_escape "${SWARM_PRE_STATE}")" \
        "${force_used_bool}" \
        "${force_leave_bool}"

    if [ "${INIT_SWARM}" -eq 1 ]; then
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
