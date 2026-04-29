#!/bin/bash
###############################################################################
# Script 03 : Rejoindre un cluster Docker Swarm existant
#
# A executer sur l'HOTE PROXMOX (pas dans le container).
#
# Le LXC cible doit avoir ete cree au prealable avec 00-create-lxc.sh --swarm
# (Docker installe + sysctl + /dev/net/tun).
#
# Pour recuperer l'IP et le token du manager existant :
#   pct exec <MANAGER_CTID> -- docker swarm join-token worker -q
#   pct exec <MANAGER_CTID> -- docker swarm join-token manager -q
#   pct exec <MANAGER_CTID> -- docker info --format '{{.Swarm.NodeAddr}}'
#
# Usage :
#   Local :
#     ./03-join-swarm.sh <NEW_CTID> <MANAGER_IP> <TOKEN> [--manager]
#
#   Via wget (sans clone du repo) :
#     bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/03-join-swarm.sh)" _ <NEW_CTID> <MANAGER_IP> <TOKEN> [--manager]
#
# Exemples :
#   # Ajouter LXC 301 comme worker au Swarm dont le manager est sur 192.168.10.115
#   ./03-join-swarm.sh 301 192.168.10.115 SWMTKN-1-xxx...
#
#   # Ajouter LXC 302 comme manager additionnel (HA)
#   ./03-join-swarm.sh 302 192.168.10.115 SWMTKN-1-yyy... --manager
#
# Variables d'environnement :
#   ADVERTISE_ADDR   IP a annoncer pour le nouveau node. Defaut : auto-detect (eth0)
#   LISTEN_ADDR      IP d'ecoute. Defaut : 0.0.0.0:2377
#   FORCE_LEAVE      Si "yes", quitte le Swarm courant avant de rejoindre. Defaut : no
###############################################################################
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
ADVERTISE_ADDR="${ADVERTISE_ADDR:-}"
LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0:2377}"
FORCE_LEAVE="${FORCE_LEAVE:-no}"

# Parsing des arguments : detection de --manager n'importe ou
JOIN_AS_MANAGER=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --manager) JOIN_AS_MANAGER=1 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]}"

CTID="${1:-}"
MANAGER_IP="${2:-}"
TOKEN="${3:-}"

# ── Pre-checks ───────────────────────────────────────────────────────────────
if [ -z "${CTID}" ] || [ -z "${MANAGER_IP}" ] || [ -z "${TOKEN}" ]; then
    echo "Usage : $0 <NEW_CTID> <MANAGER_IP> <TOKEN> [--manager]"
    echo ""
    echo "Arguments :"
    echo "  NEW_CTID     ID du LXC a faire rejoindre le cluster Swarm"
    echo "  MANAGER_IP   IP du manager Swarm existant (sans port, sera ajoute :2377)"
    echo "  TOKEN        Token de join (worker ou manager)"
    echo ""
    echo "Options :"
    echo "  --manager    Rejoindre comme manager (HA). Defaut : worker."
    echo ""
    echo "Variables d'environnement :"
    echo "  ADVERTISE_ADDR   IP a annoncer pour le nouveau node (defaut : auto-detect)"
    echo "  LISTEN_ADDR      IP d'ecoute (defaut : 0.0.0.0:2377)"
    echo "  FORCE_LEAVE      Si yes, quitte le Swarm courant avant de rejoindre"
    echo ""
    echo "Recuperer les infos depuis un manager existant :"
    echo "  pct exec <MANAGER_CTID> -- docker swarm join-token worker -q"
    echo "  pct exec <MANAGER_CTID> -- docker swarm join-token manager -q"
    echo "  pct exec <MANAGER_CTID> -- docker info --format '{{.Swarm.NodeAddr}}'"
    exit 1
fi

# Verifier que le LXC existe
if ! pct status "${CTID}" &>/dev/null; then
    echo "ERREUR : le LXC ${CTID} n'existe pas."
    echo "        Creez-le d'abord : ./00-create-lxc.sh ${CTID} <hostname> --swarm"
    exit 1
fi

# Demarrer le LXC s'il est arrete
if ! pct status "${CTID}" | grep -q running; then
    echo "  -> LXC ${CTID} arrete, demarrage..."
    pct start "${CTID}"
    sleep 5
fi

# Verifier que Docker est installe dans le LXC
if ! pct exec "${CTID}" -- bash -c "command -v docker >/dev/null && docker info >/dev/null 2>&1"; then
    echo "ERREUR : Docker n'est pas operationnel dans le LXC ${CTID}."
    echo "        Lancez d'abord : ./00-create-lxc.sh ${CTID} <hostname> --swarm"
    exit 1
fi

# Determiner le role
if [ "${JOIN_AS_MANAGER}" -eq 1 ]; then
    ROLE="manager"
else
    ROLE="worker"
fi

# Auto-detect ADVERTISE_ADDR si non fourni
if [ -z "${ADVERTISE_ADDR}" ]; then
    ADVERTISE_ADDR=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")
    if [ -z "${ADVERTISE_ADDR}" ]; then
        echo "ERREUR : impossible de detecter l'IP du LXC ${CTID}."
        echo "        Specifiez-la : ADVERTISE_ADDR=192.168.x.x $0 ..."
        exit 1
    fi
fi

# ── Affichage des parametres ─────────────────────────────────────────────────
echo "==========================================="
echo "  Join Swarm cluster"
echo "==========================================="
echo ""
echo "  Nouveau node : LXC ${CTID}"
echo "  Role         : ${ROLE}"
echo "  Manager IP   : ${MANAGER_IP}:2377"
echo "  Advertise    : ${ADVERTISE_ADDR}"
echo "  Listen       : ${LISTEN_ADDR}"
echo "  Token        : ${TOKEN:0:20}...${TOKEN: -8}"
echo ""

# ── Verifier l'etat Swarm courant du LXC ─────────────────────────────────────
SWARM_STATE=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")

if [ "${SWARM_STATE}" = "active" ]; then
    if [ "${FORCE_LEAVE}" = "yes" ]; then
        echo "  [!] LXC ${CTID} deja dans un Swarm. FORCE_LEAVE=yes -> quitter avant de rejoindre."
        pct exec "${CTID}" -- docker swarm leave --force
        echo "  -> Swarm courant quitte"
        sleep 2
    else
        echo "ERREUR : le LXC ${CTID} est deja dans un cluster Swarm actif."
        echo ""
        echo "  Pour le faire quitter d'abord :"
        echo "    pct exec ${CTID} -- docker swarm leave --force"
        echo ""
        echo "  Ou relancez ce script avec :"
        echo "    FORCE_LEAVE=yes $0 ${CTID} ${MANAGER_IP} <TOKEN>"
        exit 1
    fi
fi

# ── Test connectivite vers le manager ────────────────────────────────────────
echo "[1/3] Test de connectivite vers ${MANAGER_IP}:2377..."
if pct exec "${CTID}" -- bash -c "timeout 5 bash -c '</dev/tcp/${MANAGER_IP}/2377' 2>/dev/null"; then
    echo "  -> Manager joignable"
else
    echo "ERREUR : impossible de joindre ${MANAGER_IP}:2377 depuis le LXC ${CTID}."
    echo ""
    echo "  Verifiez :"
    echo "  - Le manager Swarm tourne et ecoute sur le port 2377"
    echo "  - Pas de firewall entre les deux LXC (port 2377 TCP, 4789 UDP, 7946 TCP+UDP)"
    echo "  - L'IP du manager est correcte"
    exit 1
fi

# ── Join Swarm ───────────────────────────────────────────────────────────────
echo "[2/3] Rejoindre le Swarm comme ${ROLE}..."
JOIN_OUTPUT=$(pct exec "${CTID}" -- docker swarm join \
    --advertise-addr "${ADVERTISE_ADDR}" \
    --listen-addr "${LISTEN_ADDR}" \
    --token "${TOKEN}" \
    "${MANAGER_IP}:2377" 2>&1)
JOIN_RC=$?

if [ ${JOIN_RC} -eq 0 ]; then
    echo "  -> ${JOIN_OUTPUT}"
else
    echo "ERREUR : echec du join Swarm."
    echo "  Sortie : ${JOIN_OUTPUT}"
    echo ""
    echo "  Causes possibles :"
    echo "  - Token invalide ou expire"
    echo "  - Token de mauvais type (worker au lieu de manager ou inverse)"
    echo "  - Manager IP incorrecte"
    echo "  - Le LXC est deja dans un autre Swarm"
    exit 1
fi

# ── Verification post-join ───────────────────────────────────────────────────
echo "[3/3] Verification..."
sleep 3

NEW_STATE=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "unknown")
NEW_ROLE=$(pct exec "${CTID}" -- docker info --format '{{if .Swarm.ControlAvailable}}manager{{else}}worker{{end}}' 2>/dev/null || echo "unknown")
NODE_ID=$(pct exec "${CTID}" -- docker info --format '{{.Swarm.NodeID}}' 2>/dev/null || echo "")

if [ "${NEW_STATE}" = "active" ]; then
    echo "  -> Etat Swarm : ${NEW_STATE}"
    echo "  -> Role       : ${NEW_ROLE}"
    echo "  -> Node ID    : ${NODE_ID}"
else
    echo "  -> ATTENTION : etat Swarm inattendu : ${NEW_STATE}"
fi

# ── Resume final ─────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  LXC ${CTID} a rejoint le Swarm"
echo "==========================================="
echo ""
echo "  Verifier depuis le manager :"
echo "    pct exec <MANAGER_CTID> -- docker node ls"
echo ""
echo "  Pour quitter le Swarm depuis ce node :"
echo "    pct exec ${CTID} -- docker swarm leave"
echo "    (ajouter --force si manager)"
echo ""
echo "==========================================="

# ── Sortie JSON (convention pipeline agflow) ─────────────────────────────────
echo "{\"status\":\"$([ "${NEW_STATE}" = "active" ] && echo ok || echo failed)\",\"ctid\":\"${CTID}\",\"role\":\"${NEW_ROLE}\",\"node_id\":\"${NODE_ID}\",\"manager_ip\":\"${MANAGER_IP}\",\"advertise_addr\":\"${ADVERTISE_ADDR}\"}"

if [ "${NEW_STATE}" != "active" ]; then
    exit 1
fi
exit 0