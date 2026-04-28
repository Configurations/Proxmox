#!/bin/bash
###############################################################################
# Script 02 : Initialisation du premier manager Docker Swarm
#
# A executer sur l'HOTE PROXMOX, vise un LXC swarm-ready (cree avec 00 --swarm).
#
# Le script :
#   - Verifie que le LXC est swarm-ready (tag, /dev/net/tun, Docker)
#   - Detecte et corrige live-restore=true incompatible avec Swarm
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
#   ADVERTISE_ADDR=<ip>        Force l'IP advertise (defaut : auto via eth0)
#   POOL_OVERLAY=10.20.0.0/16  Pool d'IPs pour les overlay networks
#   POOL_MASK=24               Masque du pool overlay
#   NODE_LABELS="k=v,k2=v2"    Labels supplementaires a poser sur le node
#   FORCE=1                    Reinitialise Swarm meme si deja actif (DESTRUCTIF)
#   AUTO_FIX=1                 Correction automatique de live-restore (defaut)
#
# Pre-requis :
#   - LXC cree via 00-create-lxc-swarm.sh ... --swarm
#   - Docker installe et operationnel dans le LXC
#   - Modules kernel ip_vs/overlay charges sur l'hote Proxmox
###############################################################################
set -uo pipefail
# Note : pas de "set -e" global pour garder le controle des erreurs
# et afficher les sorties detaillees en cas d'echec.

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTID="${1:-}"

POOL_OVERLAY="${POOL_OVERLAY:-10.20.0.0/16}"
POOL_MASK="${POOL_MASK:-24}"

DEFAULT_LABELS="role=control,tenant=agflow"
NODE_LABELS="${NODE_LABELS:-${DEFAULT_LABELS}}"

TOKEN_DIR="${TOKEN_DIR:-/root/.ssh/lxc-keys}"

FORCE="${FORCE:-0}"
AUTO_FIX="${AUTO_FIX:-1}"

if [ -z "${CTID}" ]; then
    echo "Usage : $0 <CTID>"
    echo ""
    echo "Variables d'environnement :"
    echo "  ADVERTISE_ADDR=<ip>        Force l'IP advertise (defaut : auto)"
    echo "  POOL_OVERLAY=10.20.0.0/16  Pool d'IPs pour overlay networks"
    echo "  POOL_MASK=24               Masque du pool overlay"
    echo "  NODE_LABELS=\"k=v,k2=v2\"   Labels du node"
    echo "  FORCE=1                    Reinitialise meme si Swarm actif (DESTRUCTIF)"
    echo "  AUTO_FIX=0                 Desactive la correction auto de live-restore"
    echo ""
    echo "Containers swarm-ready disponibles :"
    pct list 2>/dev/null | awk 'NR==1 || /swarm-ready/' || true
    exit 1
fi

CONF="/etc/pve/lxc/${CTID}.conf"

# Helper : exit avec message d'erreur
fail() {
    echo ""
    echo "  ECHEC : $1"
    [ -n "${2:-}" ] && echo "${2}" | sed 's/^/    /'
    exit 1
}

echo "==========================================="
echo "  Initialisation Swarm Manager"
echo "  LXC : ${CTID}"
echo "==========================================="
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# PRE-CHECKS : verifier que le LXC est swarm-ready
# ══════════════════════════════════════════════════════════════════════════════

echo "[1/7] Pre-checks LXC..."

if ! pct status "${CTID}" &>/dev/null; then
    fail "LXC ${CTID} n'existe pas" \
         "Creez-le d'abord : ./00-create-lxc-swarm.sh ${CTID} <hostname> --swarm"
fi
echo "  -> LXC existe : OK"

if ! pct status "${CTID}" | grep -q running; then
    echo "  -> LXC pas en route, demarrage..."
    pct start "${CTID}" || fail "Impossible de demarrer le LXC ${CTID}"
    sleep 5
fi
echo "  -> LXC running : OK"

if ! grep -q "^tags:.*swarm-ready" "${CONF}" 2>/dev/null; then
    fail "LXC ${CTID} n'a pas le tag 'swarm-ready'" \
         "Ce LXC n'a pas ete configure pour Swarm (manque /dev/net/tun et sysctl). Reconfigurez : ./00-create-lxc-swarm.sh ${CTID} --swarm"
fi
echo "  -> Tag swarm-ready : OK"

if ! pct exec "${CTID}" -- test -c /dev/net/tun 2>/dev/null; then
    fail "/dev/net/tun absent dans le LXC" \
         "VXLAN ne fonctionnera pas. Reconfigurez : ./00-create-lxc-swarm.sh ${CTID} --swarm"
fi
echo "  -> /dev/net/tun : OK"

if ! pct exec "${CTID}" -- bash -c "docker info >/dev/null 2>&1"; then
    fail "Docker n'est pas operationnel dans le LXC" \
         "Diagnostiquez : pct exec ${CTID} -- docker info"
fi
echo "  -> Docker operationnel : OK"

SWARM_STATE=$(pct exec "${CTID}" -- bash -c "docker info --format '{{.Swarm.LocalNodeState}}'" 2>/dev/null || echo "unknown")
if [ "${SWARM_STATE}" = "active" ]; then
    if [ "${FORCE}" -eq 1 ]; then
        echo "  -> Swarm deja actif, FORCE=1 : leave force..."
        pct exec "${CTID}" -- docker swarm leave --force >/dev/null 2>&1 || true
        echo "  -> Swarm reinitialise"
    else
        echo "  -> Swarm deja actif sur ce LXC."
        echo ""
        echo "  Etat actuel du cluster :"
        pct exec "${CTID}" -- docker node ls 2>/dev/null | sed 's/^/    /' || true
        echo ""
        echo "  Pour reinitialiser (DETRUIT le cluster) : FORCE=1 $0 ${CTID}"
        exit 0
    fi
fi
echo "  -> Pas de Swarm actif : OK"

# ══════════════════════════════════════════════════════════════════════════════
# DETECTION + FIX live-restore (incompatible avec Swarm)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[2/7] Verification de la configuration Docker (live-restore)..."

LIVE_RESTORE_ON=$(pct exec "${CTID}" -- bash -c "
if [ -f /etc/docker/daemon.json ]; then
    grep -q '\"live-restore\"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json && echo yes || echo no
else
    echo no
fi
" 2>/dev/null || echo "no")

if [ "${LIVE_RESTORE_ON}" = "yes" ]; then
    if [ "${AUTO_FIX}" -eq 1 ]; then
        echo "  -> live-restore=true detecte (incompatible Swarm), correction..."
        pct exec "${CTID}" -- bash -c "
sed -i 's/\"live-restore\":[[:space:]]*true/\"live-restore\": false/' /etc/docker/daemon.json
systemctl reload docker 2>/dev/null || systemctl restart docker
" || fail "Impossible de corriger live-restore"
        sleep 2
        echo "  -> live-restore : false (compatible Swarm)"
    else
        fail "live-restore=true detecte dans /etc/docker/daemon.json" \
             "Incompatible avec Swarm. Relancez avec AUTO_FIX=1 ou corrigez manuellement."
    fi
else
    echo "  -> live-restore : false (compatible Swarm) : OK"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Detecter l'IP advertise
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[3/7] Detection de l'IP advertise..."

if [ -n "${ADVERTISE_ADDR:-}" ]; then
    echo "  -> IP forcee via env : ${ADVERTISE_ADDR}"
else
    ADVERTISE_ADDR=$(pct exec "${CTID}" -- bash -c "ip -4 addr show eth0 2>/dev/null | grep inet | awk '{print \$2}' | cut -d/ -f1 | head -1" 2>/dev/null || echo "")
    if [ -z "${ADVERTISE_ADDR}" ]; then
        fail "Impossible de detecter l'IP du LXC sur eth0" \
             "Forcez avec : ADVERTISE_ADDR=<ip> $0 ${CTID}"
    fi
    echo "  -> IP detectee (eth0) : ${ADVERTISE_ADDR}"
fi

if ! ping -c 1 -W 2 "${ADVERTISE_ADDR}" >/dev/null 2>&1; then
    echo "  -> ATTENTION : ${ADVERTISE_ADDR} ne repond pas au ping depuis l'hote."
    echo "     Pas forcement bloquant, mais a verifier pour les futurs nodes."
fi

# ══════════════════════════════════════════════════════════════════════════════
# Verifier les conflits du pool overlay vs LAN
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[4/7] Verification du pool overlay (${POOL_OVERLAY})..."

POOL_PREFIX=$(echo "${POOL_OVERLAY}" | cut -d. -f1-2)
ADV_PREFIX=$(echo "${ADVERTISE_ADDR}" | cut -d. -f1-2)

if [ "${POOL_PREFIX}" = "${ADV_PREFIX}" ]; then
    echo "  -> ATTENTION : le pool overlay (${POOL_OVERLAY}) chevauche le subnet du LXC (${ADVERTISE_ADDR})"
    echo "     Risque de conflit reseau."
    echo ""
    read -p "  Continuer quand meme ? [y/N] " -r confirm
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        echo "  -> Abandon. Forcez un autre pool : POOL_OVERLAY=172.30.0.0/16 $0 ${CTID}"
        exit 1
    fi
fi
echo "  -> Pool overlay : ${POOL_OVERLAY} masque /${POOL_MASK}"

# ══════════════════════════════════════════════════════════════════════════════
# Initialisation Swarm (avec capture d'erreur correcte)
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[5/7] Initialisation Swarm..."

INIT_OUTPUT=$(pct exec "${CTID}" -- docker swarm init \
    --advertise-addr "${ADVERTISE_ADDR}" \
    --listen-addr "${ADVERTISE_ADDR}:2377" \
    --default-addr-pool "${POOL_OVERLAY}" \
    --default-addr-pool-mask-length "${POOL_MASK}" 2>&1)
INIT_RC=$?

if [ ${INIT_RC} -ne 0 ]; then
    echo ""
    echo "  ECHEC de docker swarm init (code ${INIT_RC}) :"
    echo "${INIT_OUTPUT}" | sed 's/^/    /'
    echo ""
    echo "  Causes courantes :"
    echo "  - live-restore=true : verifiez /etc/docker/daemon.json"
    echo "  - Conflit de subnet : essayez POOL_OVERLAY=172.30.0.0/16"
    echo "  - Module kernel manquant sur l'hote : modprobe ip_vs overlay"
    echo "  - IP mal detectee : ADVERTISE_ADDR=<ip> $0 ${CTID}"
    exit 1
fi

echo "  -> Swarm initialise"
echo "${INIT_OUTPUT}" | grep -E "(Swarm|join)" | sed 's/^/    /' || true

# ══════════════════════════════════════════════════════════════════════════════
# Recuperer les tokens
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[6/7] Recuperation des tokens..."

WORKER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token worker -q 2>/dev/null)
W_RC=$?
MANAGER_TOKEN=$(pct exec "${CTID}" -- docker swarm join-token manager -q 2>/dev/null)
M_RC=$?

if [ ${W_RC} -ne 0 ] || [ ${M_RC} -ne 0 ] || [ -z "${WORKER_TOKEN}" ] || [ -z "${MANAGER_TOKEN}" ]; then
    fail "Impossible de recuperer les tokens" \
         "Le Swarm est peut-etre actif mais l'API ne repond pas. Verifiez : pct exec ${CTID} -- docker swarm join-token worker"
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

# ══════════════════════════════════════════════════════════════════════════════
# Poser les labels sur le node
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo "[7/7] Configuration du node (labels)..."

NODE_ID=$(pct exec "${CTID}" -- docker node ls --format '{{.ID}}' 2>/dev/null | head -1)
if [ -z "${NODE_ID}" ]; then
    echo "  -> ATTENTION : impossible de recuperer le NODE_ID, labels ignores."
else
    IFS=',' read -ra LABELS_ARRAY <<< "${NODE_LABELS}"
    LABEL_ARGS=""
    for lbl in "${LABELS_ARRAY[@]}"; do
        LABEL_ARGS="${LABEL_ARGS} --label-add ${lbl}"
    done

    if [ -n "${LABEL_ARGS}" ]; then
        # shellcheck disable=SC2086
        UPDATE_OUTPUT=$(pct exec "${CTID}" -- docker node update ${LABEL_ARGS} "${NODE_ID}" 2>&1)
        UPDATE_RC=$?
        if [ ${UPDATE_RC} -ne 0 ]; then
            echo "  -> ATTENTION : echec de la pose des labels (poursuite) :"
            echo "${UPDATE_OUTPUT}" | sed 's/^/    /'
        else
            echo "  -> Labels poses : ${NODE_LABELS}"
        fi
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
echo "  - Ports    : 2377 (cluster mgmt) + 7946 (gossip) + 4789 (overlay/VXLAN)"
echo "  - Pool     : ${POOL_OVERLAY} masque /${POOL_MASK}"
echo "  - Labels   : ${NODE_LABELS}"
echo ""
echo "  Etat du cluster :"
pct exec "${CTID}" -- docker node ls 2>/dev/null | sed 's/^/  /' || true
echo ""
echo "  Tokens sauvegardes : ${TOKEN_FILE}"
echo ""
echo "  Pour ajouter un WORKER (script automatise) :"
echo "    ./03-join-swarm.sh <CTID_worker> ${CTID}"
echo ""
echo "  Pour ajouter un WORKER manuellement (depuis un node Swarm-ready) :"
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