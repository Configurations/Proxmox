#!/bin/bash
###############################################################################
# Script 02 : Initialisation du premier manager Docker Swarm
#
# A executer sur l'HOTE PROXMOX, vise un LXC swarm-ready (cree avec 00 --swarm).
#
# Le script :
#   - Verifie que le LXC est swarm-ready (tag, /dev/net/tun, Docker)
#   - Initialise le cluster Swarm sur ce LXC (premier manager)
#   - Configure le pool d'IPs overlay pour eviter les conflits LAN
#   - Pose des labels sur le node (role=control, tenant=agflow)
#   - Sauvegarde les tokens worker/manager dans /root/.ssh/lxc-keys/
#   - Affiche les commandes de join pour ajouter d'autres nodes
#
# Usage : ./02-init-swarm.sh <CTID>
# Exemple : ./02-init-swarm.sh 300
#
# Variables d'environnement :
#   ADVERTISE_ADDR=<ip>        Force l'IP advertise (defaut: auto via eth0)
#   POOL_OVERLAY=10.20.0.0/16  Pool d'IPs pour les overlay networks
#   NODE_LABELS="k=v,k2=v2"    Labels supplementaires a poser sur le node
#   FORCE=1                    Reinit Swarm meme si deja actif (DESTRUCTIF)
#
# Pre-requis :
#   - LXC cree via 00-create-lxc-swarm.sh ... --swarm
#   - Docker installe et operationnel dans le LXC
#   - Modules kernel ip_vs/overlay charges sur l'hote Proxmox
###############################################################################
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTID="${1:-}"

# Pool d'IPs pour les overlay networks Swarm.
# Defaut 10.20.0.0/16 pour eviter les conflits avec :
#   - LAN classique 192.168.x.x / 10.0.0.0/8 (defaut Swarm)
#   - Docker bridge 172.20.0.0/16 (defini dans 01-install-docker.sh)
POOL_OVERLAY="${POOL_OVERLAY:-10.20.0.0/16}"
POOL_MASK="${POOL_MASK:-24}"

# Labels par defaut poses sur le node (role=control puisque c'est le 1er manager)
DEFAULT_LABELS="role=control,tenant=agflow"
NODE_LABELS="${NODE_LABELS:-${DEFAULT_LABELS}}"

# Repertoire pour sauvegarder les tokens (meme que les clefs SSH du 00)
TOKEN_DIR="${TOKEN_DIR:-/root/.ssh/lxc-keys}"

FORCE="${FORCE:-0}"

if [ -z "${CTID}" ]; then
    echo "Usage: $0 <CTID>"
    echo ""
    echo "Variables d'environnement :"
    echo "  ADVERTISE_ADDR=<ip>        Force l'IP advertise (defaut: auto)"
    echo "  POOL_OVERLAY=10.20.0.0/16  Pool d'IPs pour overlay networks"
    echo "  NODE_LABELS=\"k=v,k2=v2\"   Labels du node"
    echo "  FORCE=1                    Reinit meme si Swarm actif (DESTRUCTIF)"
    echo ""
    echo "Containers swarm-ready disponibles :"
    pct list 2>/dev/null | awk 'NR==1 || /swarm-ready/'
    exit 1
fi

CONF="/etc/pve/lxc/${CTID}.conf"

echo "==========================================="
echo "  Initialisation Swarm Manager"
echo "  LXC : ${CTID}"
echo "==========================================="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PRE-CHECKS : verifier que le LXC est swarm-ready
# ══════════════════════════════════════════════════════════════════════════════

echo "[1/6] Pre-checks LXC..."

# Check 1 : le LXC existe
if ! pct status "${CTID}" &>/dev/null; then
    echo "  -> ERREUR : LXC ${CTID} n'existe pas."
    echo "     Creez-le d'abord avec : ./00-create-lxc-swarm.sh ${CTID} <hostname> --swarm"
    exit 1
fi
echo "  -> LXC existe : OK"

# Check 2 : le LXC tourne
if ! pct status "${CTID}" | grep -q running; then
    echo "  -> LXC pas en route, demarrage..."
    pct start "${CTID}"
    sleep 5
fi
echo "  -> LXC running : OK"

# Check 3 : tag swarm-ready
if ! grep -q "^tags:.*swarm-ready" "${CONF}" 2>/dev/null; then
    echo "  -> ERREUR : LXC ${CTID} n'a pas le tag 'swarm-ready'."
    echo "     Ce LXC n'a pas ete configure pour Swarm (manque /dev/net/tun et sysctl)."
    echo "     Reconfigurez-le avec : ./00-create-lxc-swarm.sh ${CTID} --swarm"
    exit 1
fi
echo "  -> Tag swarm-ready : OK"

# Check 4 : /dev/net/tun present dans le LXC
if ! pct exec "${CTID}" -- test -c /dev/net/tun 2>/dev/null; then
    echo "  -> ERREUR : /dev/net/tun absent dans le LXC."
    echo "     VXLAN ne fonctionnera pas. Reconfigurez le LXC :"
    echo "     ./00-create-lxc-swarm.sh ${CTID} --swarm"
    exit 1
fi
echo "  -> /dev/net/tun : OK"

# Check 5 : Docker operationnel
if ! pct exec "${CTID}" -- bash -c "docker info >/dev/null 2>&1"; then
    echo "  -> ERREUR : Docker n'est pas operationnel dans le LXC."
    echo "     Diagnostiquez avec : pct exec ${CTID} -- docker info"
    exit 1
fi
echo "  -> Docker operationnel : OK"

# Check 6 : Swarm pas deja actif (sauf FORCE)
SWARM_STATE=$(pct exec "${CTID}" -- bash -c "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null || echo "unknown")
if [ "${SWARM_STATE}" = "active" ]; then
    if [ "${FORCE}" -eq 1 ]; then
        echo "  -> Swarm deja actif, FORCE=1 : leave force..."
        pct exec "${CTID}" -- docker swarm leave --force >/dev/null 2>&1 || true
        echo "  -> Swarm reset"
    else
        echo "  -> Swarm deja actif sur ce LXC."
        echo ""
        echo "  Etat actuel du cluster :"
        pct exec "${CTID}" -- docker node ls 2>/dev/null | sed 's/^/    /'
        echo ""
        echo "  Pour reinitialiser (ATTENTION : detruit le cluster), utilisez : FORCE=1 $0 ${CTID}"
        exit 0
    fi
fi
echo "  -> Pas de Swarm actif : OK"

# ══════════════════════════════════════════════════════════════════════════════
# Detecter l'IP advertise
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[2/6] Detection de l'IP advertise..."

if [ -n "${ADVERTISE_ADDR:-}" ]; then
    echo "  -> IP forcee via env : ${ADVERTISE_ADDR}"
else
    ADVERTISE_ADDR=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")
    if [ -z "${ADVERTISE_ADDR}" ]; then
        echo "  -> ERREUR : impossible de detecter l'IP du LXC sur eth0."
        echo "     Forcez avec : ADVERTISE_ADDR=<ip> $0 ${CTID}"
        exit 1
    fi
    echo "  -> IP detectee (eth0) : ${ADVERTISE_ADDR}"
fi

# Verifier que l'IP est joignable depuis l'hote (test reseau basique)
if ! ping -c 1 -W 2 "${ADVERTISE_ADDR}" >/dev/null 2>&1; then
    echo "  -> ATTENTION : ${ADVERTISE_ADDR} ne repond pas au ping depuis l'hote."
    echo "     Ce n'est pas forcement bloquant, mais a verifier si vous voulez ajouter d'autres nodes."
fi

# ══════════════════════════════════════════════════════════════════════════════
# Detecter conflit du pool overlay avec le LAN
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[3/6] Verification du pool overlay (${POOL_OVERLAY})..."

# Extraire les premiers octets du pool overlay et de l'IP advertise
POOL_PREFIX=$(echo "${POOL_OVERLAY}" | cut -d. -f1-2)
ADV_PREFIX=$(echo "${ADVERTISE_ADDR}" | cut -d. -f1-2)

if [ "${POOL_PREFIX}" = "${ADV_PREFIX}" ]; then
    echo "  -> ATTENTION : le pool overlay (${POOL_OVERLAY}) chevauche le subnet du LXC (${ADVERTISE_ADDR})"
    echo "     Risque de conflit reseau. Forcez un autre pool :"
    echo "       POOL_OVERLAY=172.30.0.0/16 $0 ${CTID}"
    echo ""
    read -p "  Continuer quand meme ? [y/N] " -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "  -> Abandon."
        exit 1
    fi
fi
echo "  -> Pool overlay : ${POOL_OVERLAY} (mask /${POOL_MASK})"

# ══════════════════════════════════════════════════════════════════════════════
# Init Swarm
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[4/6] Initialisation Swarm..."

INIT_OUTPUT=$(pct exec "${CTID}" -- docker swarm init \
    --advertise-addr "${ADVERTISE_ADDR}" \
    --listen-addr "${ADVERTISE_ADDR}:2377" \
    --default-addr-pool "${POOL_OVERLAY}" \
    --default-addr-pool-mask-length "${POOL_MASK}" 2>&1)

if [ $? -ne 0 ]; then
    echo "  -> ERREUR : docker swarm init a echoue."
    echo "${INIT_OUTPUT}" | sed 's/^/    /'
    exit 1
fi

echo "  -> Swarm initialise"
echo "${INIT_OUTPUT}" | grep -E "(Swarm|join)" | sed 's/^/    /' || true

# ══════════════════════════════════════════════════════════════════════════════
# Recuperer les tokens
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[5/6] Recuperation des tokens..."

WORKER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token worker -q 2>/dev/null)
MANAGER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token manager -q 2>/dev/null)

if [ -z "${WORKER_TOKEN}" ] || [ -z "${MANAGER_TOKEN}" ]; then
    echo "  -> ERREUR : impossible de recuperer les tokens."
    exit 1
fi

# Sauvegarde locale sur l'hote Proxmox (chmod 600)
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

# ══════════════════════════════════════════════════════════════════════════════
# Poser les labels sur le node
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[6/6] Configuration du node (labels)..."

NODE_ID=$(pct exec "${CTID}" -- docker node ls --format '{{.ID}}' 2>/dev/null | head -1)
if [ -z "${NODE_ID}" ]; then
    echo "  -> ATTENTION : impossible de recuperer le NODE_ID, skip labels."
else
    # Convertir "role=control,tenant=agflow" en plusieurs --label-add
    IFS=',' read -ra LABELS_ARRAY <<< "${NODE_LABELS}"
    LABEL_ARGS=""
    for lbl in "${LABELS_ARRAY[@]}"; do
        LABEL_ARGS="${LABEL_ARGS} --label-add ${lbl}"
    done

    if [ -n "${LABEL_ARGS}" ]; then
        # shellcheck disable=SC2086
        pct exec "${CTID}" -- docker node update ${LABEL_ARGS} "${NODE_ID}" >/dev/null 2>&1
        echo "  -> Labels poses : ${NODE_LABELS}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Resume final
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "==========================================="
echo "  Swarm initialise sur LXC ${CTID}"
echo "==========================================="
echo ""
echo "  Manager :"
echo "  - LXC      : ${CTID}"
echo "  - IP       : ${ADVERTISE_ADDR}"
echo "  - Port     : 2377 (cluster mgmt) + 7946 (gossip) + 4789 (overlay/VXLAN)"
echo "  - Pool     : ${POOL_OVERLAY} mask /${POOL_MASK}"
echo "  - Labels   : ${NODE_LABELS}"
echo ""
echo "  Etat du cluster :"
pct exec "${CTID}" -- docker node ls 2>/dev/null | sed 's/^/  /'
echo ""
echo "  Tokens sauvegardes : ${TOKEN_FILE}"
echo ""
echo "  Pour ajouter un WORKER (depuis l'hote Proxmox) :"
echo "    ./03-join-swarm.sh <CTID_worker> ${CTID}"
echo ""
echo "  Pour ajouter un WORKER manuellement (depuis n'importe quel node Swarm-ready) :"
echo "    docker swarm join --token ${WORKER_TOKEN} ${ADVERTISE_ADDR}:2377"
echo ""
echo "  Pour ajouter un MANAGER (HA, recommande 3+ managers en prod) :"
echo "    docker swarm join --token ${MANAGER_TOKEN} ${ADVERTISE_ADDR}:2377"
echo ""
echo "  Test du cluster :"
echo "    pct exec ${CTID} -- docker node ls"
echo "    pct exec ${CTID} -- docker network ls    # voir l'overlay 'ingress'"
echo ""
echo "==========================================="
echo ""

# ── Sortie JSON (convention pipeline agflow) ─────────────────────────────────
NODE_HOSTNAME=$(pct exec "${CTID}" -- hostname 2>/dev/null || echo "")
echo "{\"status\":\"ok\",\"manager_ctid\":\"${CTID}\",\"manager_ip\":\"${ADVERTISE_ADDR}\",\"manager_port\":2377,\"hostname\":\"${NODE_HOSTNAME}\",\"pool_overlay\":\"${POOL_OVERLAY}\",\"pool_mask\":${POOL_MASK},\"labels\":\"${NODE_LABELS}\",\"token_file\":\"${TOKEN_FILE}\"}"