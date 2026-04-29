#!/bin/bash
###############################################################################
# Script 00 : Creation / Configuration LXC Proxmox pour Docker (+ Swarm)
#
# A executer sur l'HOTE PROXMOX (pas dans le container).
#
# Deux modes automatiques :
#   - Si le container N'EXISTE PAS  -> creation + configuration Docker
#   - Si le container EXISTE DEJA   -> reconfiguration Docker (avec backup)
#
# Mode Swarm (option --swarm) :
#   - Charge les modules kernel ip_vs/overlay sur l'hote (une fois)
#   - Ajoute /dev/net/tun au container (necessaire pour VXLAN)
#   - Configure les sysctl reseau dans le container
#   - Tag le container "swarm-ready"
#   L'initialisation Swarm se fait via 02-init-swarm.sh (separe).
#
# Storage automatique (STORAGE=auto, par defaut) :
#   - Affiche un tableau de bord des storages disponibles
#   - Selectionne automatiquement celui avec le plus d'espace libre
#   - Verifie l'espace disponible AVANT pct create
#   - Refuse la creation si pas assez de place et suggere une alternative
#
# Verification post-installation Docker :
#   - Verifie que Docker est operationnel a la fin
#   - Echec clair si l'installation a plante (ex : pool sature en cours de route)
#
# Resout :
#   - AppArmor "permission denied"
#   - Network unreachable (pas de DHCP)
#   - Docker sysctl errors
#   - Nesting / cgroup permissions
#   - UID/GID remapping (unprivileged -> privileged)
#   - VXLAN / overlay network pour Swarm
#   - Storage sature (selection automatique d'un pool avec assez de place)
#   - Installation Docker incomplete (verification post-install)
#
# Inclut :
#   - Generation de clefs SSH (sauvegardees sur l'hote)
#   - Configuration openssh-server dans le container
#   - Installation Docker via 01-install-docker.sh (si present dans le meme dossier)
#
# Usage : ./00-create-lxc-swarm.sh <CTID> [hostname] [--swarm]
# Exemples :
#   ./00-create-lxc-swarm.sh 200 agflow-docker-test
#   ./00-create-lxc-swarm.sh 201 agflow-swarm-mgr --swarm
#   STORAGE=extended-lvm ./00-create-lxc-swarm.sh 201 agflow-swarm-mgr --swarm
#   STORAGE=auto DISK_SIZE=50 ./00-create-lxc-swarm.sh 202 agflow-data --swarm
#
# Pre-requis (creation uniquement) : un template Ubuntu dans le storage local.
#   pveam update
#   pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
###############################################################################
set -euo pipefail

# ── Configuration par defaut ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parsing des arguments : detection de --swarm n'importe ou dans la liste
SWARM_MODE=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --swarm) SWARM_MODE=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

CTID="${1:-}"
# Sanitize hostname : remplacer underscores/points par tirets, en minuscules
CT_NAME_RAW="${2:-agflow-docker}"
CT_NAME=$(echo "${CT_NAME_RAW}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
SWAP="${SWAP:-1024}"
DISK_SIZE="${DISK_SIZE:-30}"
STORAGE="${STORAGE:-auto}"
BRIDGE="${BRIDGE:-vmbr0}"
SSH_KEY_DIR="${SSH_KEY_DIR:-/root/.ssh/lxc-keys}"

# Marge de securite : on ne creera pas un disque qui remplirait le pool a +X%
SAFETY_MARGIN_GB="${SAFETY_MARGIN_GB:-5}"

if [ -z "${CTID}" ]; then
    echo "Usage : $0 <CTID> [hostname] [--swarm]"
    echo ""
    echo "Options :"
    echo "  --swarm    Configure le LXC pour qu'il soit un node Docker Swarm"
    echo "             (modules kernel hote, /dev/net/tun, sysctl reseau)"
    echo ""
    echo "Variables d'environnement :"
    echo "  STORAGE=auto         Selection automatique du storage avec le plus d'espace (defaut)"
    echo "  STORAGE=<nom>        Force un storage specifique (ex : extended-lvm, local-lvm)"
    echo "  DISK_SIZE=30         Taille du disque rootfs en GB (defaut 30)"
    echo "  CORES=4              Nombre de coeurs CPU (defaut 4)"
    echo "  MEMORY=8192          RAM en MB (defaut 8192)"
    echo "  SAFETY_MARGIN_GB=5   Marge minimale a laisser libre dans le pool (defaut 5)"
    echo ""
    echo "Containers disponibles :"
    pct list
    exit 1
fi

CONF="/etc/pve/lxc/${CTID}.conf"

# ══════════════════════════════════════════════════════════════════════════════
# TABLEAU DE BORD STORAGES + SELECTION AUTOMATIQUE
# ══════════════════════════════════════════════════════════════════════════════
# Affiche tous les storages utilisables pour rootfs LXC, indique leur etat,
# et permet la selection automatique du meilleur (STORAGE=auto).

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

# Trouve le storage avec le plus d'espace libre, parmi ceux qui supportent rootfs
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

# Verifie qu'un storage donne a assez de place pour creer le disque demande
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

# Affiche le tableau de bord et resout STORAGE=auto si necessaire (mode CREATION uniquement)
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

    # Verification d'espace AVANT toute creation
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
# PRE-REQUIS HOTE PROXMOX : modules kernel pour Swarm
# ══════════════════════════════════════════════════════════════════════════════
# Idempotent. Ne configure les modules que si --swarm est demande.

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

    LOADED=$(lsmod | awk '{print $1}' | grep -cE '^(ip_vs|overlay|br_netfilter|nf_conntrack)$' || true)
    echo "  -> Modules charges : ${LOADED}/4 (ip_vs/overlay/br_netfilter/nf_conntrack)"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
# Detecter le mode : CREATION ou RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
if pct status "${CTID}" &>/dev/null; then
    MODE="reconfigure"
    echo "==========================================="
    echo "  Container ${CTID} detecte -> RECONFIGURATION"
    [ "${SWARM_MODE}" -eq 1 ] && echo "  Mode Swarm : ACTIVE"
    echo "==========================================="
else
    MODE="create"
    echo "==========================================="
    echo "  Container ${CTID} inexistant -> CREATION"
    [ "${SWARM_MODE}" -eq 1 ] && echo "  Mode Swarm : ACTIVE"
    echo "==========================================="
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# MODE CREATION
# ══════════════════════════════════════════════════════════════════════════════
if [ "${MODE}" = "create" ]; then

    # ── Detecter le template Ubuntu ──────────────────────────────────────────
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

    if [ "${SWARM_MODE}" -eq 1 ]; then
        CT_TAGS="agflow,docker,swarm-ready"
        CT_DESCRIPTION="agflow.docker platform (Swarm node)"
    else
        CT_TAGS="agflow,docker"
        CT_DESCRIPTION="agflow.docker platform"
    fi

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

    # ── Creer le container (directement privileged) ──────────────────────────
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

    # ── Ajouter la config Docker ─────────────────────────────────────────────
    echo "[2/3] Ajout de la configuration Docker-ready..."
    cat >> "${CONF}" << 'EOF'

# Docker dans LXC : permissions necessaires
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw cgroup:rw
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /sys/kernel/security sys/kernel/security none bind,optional 0 0
EOF

    # ── Ajouter la config Swarm si demandee ──────────────────────────────────
    if [ "${SWARM_MODE}" -eq 1 ]; then
        cat >> "${CONF}" << 'EOF'

# Docker Swarm : overlay network (VXLAN) requiert /dev/net/tun
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
EOF
        echo "  -> Configuration Docker + Swarm ajoutee"
    else
        echo "  -> Configuration Docker ajoutee"
    fi

    STEP_BOOT=3
    STEP_TOTAL=3

# ══════════════════════════════════════════════════════════════════════════════
# MODE RECONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
else

    # ── Detecter une conversion unprivileged -> privileged ───────────────────
    WAS_UNPRIVILEGED=0
    if grep -q "^unprivileged: 1" "${CONF}" 2>/dev/null; then
        WAS_UNPRIVILEGED=1
        echo "  [!] Container actuellement unprivileged -> sera converti en privileged"
        echo "      Les UIDs/GIDs du systeme de fichiers seront corriges automatiquement."
        echo ""
    fi

    # ── Arreter le container ─────────────────────────────────────────────────
    echo "[1/6] Arret du container ${CTID}..."
    pct stop "${CTID}" 2>/dev/null || true
    sleep 3
    echo "  -> Arrete"

    # ── Backup ───────────────────────────────────────────────────────────────
    echo "[2/6] Backup de la configuration..."
    cp "${CONF}" "${CONF}.backup.$(date +%Y%m%d%H%M%S)"
    echo "  -> Backup : ${CONF}.backup.*"

    # ── Lire les parametres existants ────────────────────────────────────────
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

    # ── Remapping UIDs si necessaire ─────────────────────────────────────────
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

    # ── Calculer la ligne tags (ajouter swarm-ready si --swarm) ──────────────
    if [ "${SWARM_MODE}" -eq 1 ]; then
        if [ -z "${EXISTING_TAGS}" ]; then
            TAGS_LINE="tags: agflow;docker;swarm-ready"
        elif echo "${EXISTING_TAGS}" | grep -q "swarm-ready"; then
            TAGS_LINE="tags: ${EXISTING_TAGS}"
        else
            TAGS_LINE="tags: ${EXISTING_TAGS};swarm-ready"
        fi
    else
        if [ -n "${EXISTING_TAGS}" ]; then
            TAGS_LINE="tags: ${EXISTING_TAGS}"
        else
            TAGS_LINE=""
        fi
    fi

    # ── Ecrire la configuration Docker-ready ─────────────────────────────────
    echo "[5/6] Ecriture de la configuration Docker-ready..."
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

# Docker dans LXC : permissions necessaires
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw cgroup:rw
lxc.cgroup2.devices.allow: a
lxc.mount.entry: /sys/kernel/security sys/kernel/security none bind,optional 0 0
EOF

    if [ "${SWARM_MODE}" -eq 1 ]; then
        cat >> "${CONF}" << 'EOF'

# Docker Swarm : overlay network (VXLAN) requiert /dev/net/tun
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file 0 0
EOF
        echo "  -> Configuration ecrite (Docker + Swarm)"
    else
        echo "  -> Configuration ecrite"
    fi

    sed -i '/./,$!d' "${CONF}"

    STEP_BOOT=6
    STEP_TOTAL=6
fi

# ══════════════════════════════════════════════════════════════════════════════
# COMMUN : Demarrage + Reseau + SSH + Docker
# ══════════════════════════════════════════════════════════════════════════════

# ── Demarrage ────────────────────────────────────────────────────────────────
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

# ── Configuration sysctl Swarm dans le container ─────────────────────────────
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

# ── Configuration SSH ────────────────────────────────────────────────────────
echo ""
echo "  Configuration SSH..."

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
if ! command -v sshd &>/dev/null; then
    echo '  -> Installation de openssh-server...'
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq openssh-server >/dev/null 2>&1
    echo '  -> openssh-server installe'
else
    echo '  -> openssh-server deja present'
fi

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

# ── Installation Docker via 01-install-docker.sh ─────────────────────────────
DOCKER_INSTALL_OK=0
DOCKER_SCRIPT="${SCRIPT_DIR}/01-install-docker.sh"
if [ -f "${DOCKER_SCRIPT}" ]; then
    echo ""
    echo "  Installation Docker via 01-install-docker.sh..."
    pct push "${CTID}" "${DOCKER_SCRIPT}" /root/01-install-docker.sh
    pct exec "${CTID}" -- chmod +x /root/01-install-docker.sh

    if pct exec "${CTID}" -- /root/01-install-docker.sh; then
        DOCKER_INSTALL_OK=1
    else
        DOCKER_INSTALL_OK=0
        echo "  [!] L'installation Docker a echoue (code de sortie != 0)"
    fi
else
    echo ""
    echo "  [!] ${DOCKER_SCRIPT} introuvable -- installation Docker ignoree."
fi

# ── Verification post-installation Docker ────────────────────────────────────
echo ""
echo "  Verification post-installation Docker..."

DOCKER_OK=0
if pct exec "${CTID}" -- bash -c "command -v docker >/dev/null && docker info >/dev/null 2>&1"; then
    DOCKER_OK=1
    echo "  -> Docker daemon : OK (operationnel)"

    if pct exec "${CTID}" -- docker run --rm hello-world >/dev/null 2>&1; then
        echo "  -> Docker run    : OK (test hello-world reussi)"
    else
        echo "  -> Docker run    : ECHEC (probleme reseau ou pull registry)"
    fi
else
    echo "  -> ERREUR : Docker n'est pas operationnel."
    echo ""
    echo "  Causes probables :"
    echo "  - Pool storage sature en cours d'installation (No space left on device)"
    echo "  - Repository Docker inaccessible (probleme reseau)"
    echo "  - Conflit de paquets"
    echo ""
    echo "  Diagnostic :"
    echo "  - Espace disque dans le LXC :"
    pct exec "${CTID}" -- df -h / 2>/dev/null | tail -n +2 | sed 's/^/    /'
    echo "  - Espace dans les pools Proxmox :"
    pvesm status 2>/dev/null | awk 'NR>1 {printf "    %-20s %s%%\n", $1, int($5*100/$4)}'
    echo ""
    echo "  Pour relancer l'installation Docker manuellement (apres avoir libere de l'espace) :"
    echo "    pct exec ${CTID} -- bash /root/01-install-docker.sh"
fi

# ── Creer un utilisateur agflow avec SSH ed25519 ────────────────────────────
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

pct exec "${CTID}" -- bash -c "
if ! id agflow &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,docker agflow 2>/dev/null || useradd -m -s /bin/bash agflow
    echo '  -> Utilisateur agflow cree'
else
    echo '  -> Utilisateur agflow existant'
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

# ── Recuperer les infos systeme ──────────────────────────────────────────────
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

# Verification finale Swarm-ready
SWARM_READY="false"
if [ "${SWARM_MODE}" -eq 1 ]; then
    TUN_OK=$(pct exec "${CTID}" -- bash -c "[ -c /dev/net/tun ] && echo yes || echo no" 2>/dev/null || echo "no")
    if [ "${TUN_OK}" = "yes" ] && [ "${DOCKER_OK}" -eq 1 ]; then
        SWARM_READY="true"
    fi
fi

# ── Resume final ─────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
if [ "${DOCKER_OK}" -eq 1 ]; then
    echo "  Container ${CTID} PRET"
else
    echo "  Container ${CTID} CREE (Docker NON operationnel)"
fi
echo "==========================================="
echo ""
echo "  Mode        : ${MODE}"
[ "${SWARM_MODE}" -eq 1 ] && echo "  Swarm-ready : ${SWARM_READY}"
echo ""
echo "  Systeme :"
echo "  - Distribution : ${CT_DISTRO}"
echo "  - IP           : ${CT_IP} (${IP_TYPE})"
echo ""
echo "  Infrastructure :"
echo "  - unprivileged : 0 (privileged)"
echo "  - nesting + keyctl actives"
echo "  - AppArmor : unconfined"
echo "  - cgroup2 : tous devices autorises"
if [ "${SWARM_MODE}" -eq 1 ]; then
echo "  - /dev/net/tun monte (VXLAN ready)"
echo "  - sysctl Swarm appliques"
fi
echo ""
echo "  SSH :"
echo "  - Clef privee  : ${KEY_FILE}"
echo "  - Clef publique : ${KEY_FILE}.pub"
echo "  - Connexion root par clef uniquement"
echo ""
echo "  Acces :"
echo "    pct enter ${CTID}"
if [ -n "${CT_IP}" ]; then
echo "    ssh -i ${KEY_FILE} root@${CT_IP}"
echo ""
echo "  IP : ${CT_IP}"
fi
echo ""
echo "  Utilisateur agflow :"
echo "  - User     : agflow"
echo "  - Password : ${AGFLOW_PASS}"
echo "  - Clef SSH : ${AGFLOW_KEY_FILE}"
echo "  - sudo     : NOPASSWD"
if [ -n "${CT_IP}" ]; then
echo "    ssh -i ${AGFLOW_KEY_FILE} agflow@${CT_IP}"
fi
echo ""
echo "  Docker :"
docker_version=$(pct exec "${CTID}" -- docker --version 2>/dev/null || echo "non installe")
compose_version=$(pct exec "${CTID}" -- docker compose version 2>/dev/null || echo "non installe")
echo "    ${docker_version}"
echo "    ${compose_version}"
if [ "${DOCKER_OK}" -eq 0 ]; then
    echo ""
    echo "  [!] DOCKER N'EST PAS OPERATIONNEL"
    echo "      Voir le diagnostic ci-dessus pour plus de details."
fi
if [ "${SWARM_MODE}" -eq 1 ] && [ "${DOCKER_OK}" -eq 1 ]; then
    echo ""
    echo "  Prochaine etape Swarm :"
    echo "    - Premier manager : ./02-init-swarm.sh ${CTID}"
    echo "    - Worker/manager  : ./03-join-swarm.sh ${CTID} <token> <manager-ip>"
fi
echo ""
echo "==========================================="
echo ""

# ── Sortie JSON (convention pipeline agflow) ─────────────────────────────────
echo "{\"status\":\"$([ ${DOCKER_OK} -eq 1 ] && echo ok || echo partial)\",\"ctid\":\"${CTID}\",\"ip\":\"${CT_IP}\",\"ip_type\":\"${IP_TYPE}\",\"distro\":\"${CT_DISTRO}\",\"user\":\"agflow\",\"password\":\"${AGFLOW_PASS}\",\"ssh_key\":\"${AGFLOW_KEY_FILE}\",\"docker\":\"${docker_version}\",\"docker_ok\":${DOCKER_OK},\"storage\":\"${STORAGE}\",\"swarm_mode\":${SWARM_MODE},\"swarm_ready\":${SWARM_READY}}"

# Code de sortie : 0 si tout OK, 2 si Docker pas operationnel mais LXC cree
if [ "${DOCKER_OK}" -eq 0 ]; then
    exit 2
fi
exit 0