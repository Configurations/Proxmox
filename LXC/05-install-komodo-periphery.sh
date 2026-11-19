#!/bin/bash
###############################################################################
# Script 05 : Installation Komodo Periphery (agent de deploiement)
#
# A executer DANS le container LXC ou la VM (en tant que root).
#
# Deploie le periphery Komodo via docker-compose (image officielle
# ghcr.io/moghtech/komodo-periphery:2). Le periphery se connecte EN SORTIE
# vers le Core Komodo : aucun port entrant a exposer.
#
# REQUIERT DOCKER : pas de mode systemd pour cette app.
#
# Variables d'environnement requises :
#   KOMODO_ADDRESS      - adresse du Core Komodo, ex : https://komodo.example.org
#   KOMODO_SERVER_NAME  - nom du Server Komodo (doit matcher un Server existant,
#                         ou etre cree automatiquement via l'onboarding key)
#
# Variables optionnelles :
#   KOMODO_ONBOARDING_KEY    - "Server Onboarding Key" creee dans l'UI Komodo ;
#                              permet de creer le Server s'il n'existe pas
#   PERIPHERY_ROOT_DIRECTORY - racine des composes/repos geres (defaut /etc/komodo)
#   STRICT_CHECKS=1          - echec si le Core est injoignable (defaut : 0)
#   SRC_DIR=...              - dossier source des fichiers (defaut : /tmp/komodo-periphery)
#   DST_DIR=...              - dossier d'installation (defaut : /opt/komodo-periphery)
#
# Pre-requis :
#   - ${SRC_DIR}/ contient docker-compose.yml (version agflow du compose officiel)
###############################################################################
set -euo pipefail

KOMODO_ADDRESS="${KOMODO_ADDRESS:-}"
KOMODO_SERVER_NAME="${KOMODO_SERVER_NAME:-$(hostname)}"
KOMODO_ONBOARDING_KEY="${KOMODO_ONBOARDING_KEY:-}"
PERIPHERY_ROOT_DIRECTORY="${PERIPHERY_ROOT_DIRECTORY:-/etc/komodo}"
SRC_DIR="${SRC_DIR:-/tmp/komodo-periphery}"
DST_DIR="${DST_DIR:-/opt/komodo-periphery}"
STRICT_CHECKS="${STRICT_CHECKS:-0}"

echo "==========================================="
echo "  Installation Komodo Periphery"
echo "==========================================="
echo "  Core         : ${KOMODO_ADDRESS}"
echo "  Server name  : ${KOMODO_SERVER_NAME}"
echo "  Onboarding   : $([ -n "${KOMODO_ONBOARDING_KEY}" ] && echo "oui (key fournie)" || echo "non (Server deja existant attendu)")"
echo "  Root dir     : ${PERIPHERY_ROOT_DIRECTORY}"
echo "  Source dir   : ${SRC_DIR}"
echo "  Target dir   : ${DST_DIR}"
echo "  Strict mode  : ${STRICT_CHECKS}"
echo ""

if [ -z "${KOMODO_ADDRESS}" ]; then
    echo "ERREUR : KOMODO_ADDRESS doit etre defini (ex : https://komodo.example.org)."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERREUR : Ce script doit etre execute en tant que root."
    exit 1
fi

if [ ! -d "${SRC_DIR}" ]; then
    echo "ERREUR : Source dir ${SRC_DIR} introuvable."
    echo "         Copier komodo-periphery/docker-compose.yml dans ${SRC_DIR} avant d'executer."
    exit 1
fi

# ── Docker obligatoire ───────────────────────────────────────────────────────
if ! command -v docker &>/dev/null || [ ! -S /var/run/docker.sock ]; then
    echo "ERREUR : Docker est requis pour Komodo Periphery (pas de mode systemd)."
    echo "         Creez la machine avec --docker, ou installez Docker d'abord."
    exit 1
fi
echo "  Docker detecte : OK"

# ── Test connectivite Core (warning ou error selon STRICT_CHECKS) ────────────
echo "  Test de connectivite vers le Core Komodo..."
CORE_TEST_URL="${KOMODO_ADDRESS}"
case "${CORE_TEST_URL}" in
    http://*|https://*) : ;;
    *) CORE_TEST_URL="https://${CORE_TEST_URL}" ;;
esac

CORE_OK=0
# Toute reponse HTTP (meme 404) prouve que le Core repond.
if curl -s --max-time 5 -o /dev/null "${CORE_TEST_URL}"; then
    CORE_OK=1
    echo "  -> Core joignable : OK (${CORE_TEST_URL})"
fi

if [ "${CORE_OK}" -eq 0 ]; then
    if [ "${STRICT_CHECKS}" -eq 1 ]; then
        echo "  -> ERREUR : Core injoignable sur ${CORE_TEST_URL}"
        echo "             Mode strict actif (STRICT_CHECKS=1) : abandon."
        exit 1
    else
        echo "  -> ATTENTION : Core injoignable sur ${CORE_TEST_URL}"
        echo "                Le periphery demarrera quand meme et retentera de se connecter."
        echo "                Pour echouer dans ce cas : STRICT_CHECKS=1"
    fi
fi
echo ""

# ── Deploiement ──────────────────────────────────────────────────────────────
mkdir -p "${DST_DIR}"
mkdir -p "${PERIPHERY_ROOT_DIRECTORY}"

echo "[1/4] Copie des fichiers vers ${DST_DIR}..."
cp "${SRC_DIR}/docker-compose.yml" "${DST_DIR}/"
echo "  -> OK"

echo "[2/4] Ecriture .env..."
cat > "${DST_DIR}/.env" << EOF
KOMODO_ADDRESS=${KOMODO_ADDRESS}
KOMODO_SERVER_NAME=${KOMODO_SERVER_NAME}
KOMODO_ONBOARDING_KEY=${KOMODO_ONBOARDING_KEY}
PERIPHERY_ROOT_DIRECTORY=${PERIPHERY_ROOT_DIRECTORY}
EOF
chmod 600 "${DST_DIR}/.env"
echo "  -> ${DST_DIR}/.env (chmod 600, contient l'onboarding key)"

echo "[3/4] Demarrage du container periphery..."
cd "${DST_DIR}"
PULL_OK=0
for attempt in 1 2 3; do
    if docker compose pull 2>&1; then
        PULL_OK=1
        break
    fi
    echo "  -> Tentative ${attempt}/3 echouee, retry dans 3s..."
    sleep 3
done
if [ "${PULL_OK}" -eq 0 ]; then
    echo "  ERREUR : impossible de puller l'image periphery apres 3 tentatives."
    exit 1
fi
docker compose up -d
echo "  -> OK"

echo "[4/4] Verification post-install..."
sleep 4
CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' agflow-komodo-periphery 2>/dev/null || echo "unknown")

if echo "${CONTAINER_STATE}" | grep -qiE "running|up"; then
    echo "  -> Container periphery : OK (${CONTAINER_STATE})"
else
    echo "  -> ERREUR : Container periphery n'est pas en running (etat : ${CONTAINER_STATE})"
    echo ""
    echo "  Logs des 20 dernieres lignes :"
    docker compose logs --tail 20 2>&1 | sed 's/^/    /'
    exit 1
fi

# Verifier les erreurs de connexion au Core
sleep 2
PERIPHERY_LOGS=$(docker compose logs --tail 50 2>/dev/null || echo "")
if echo "${PERIPHERY_LOGS}" | grep -qiE "unauthorized|failed to connect|connection refused|no route to host"; then
    if [ "${STRICT_CHECKS}" -eq 1 ]; then
        echo "  -> ERREUR : le periphery a des erreurs de connexion au Core"
        echo "${PERIPHERY_LOGS}" | grep -iE "error|unauthorized|refused|failed" | tail -5 | sed 's/^/    /'
        exit 1
    else
        echo "  -> ATTENTION : erreurs de connexion au Core (continue, retry auto)"
        echo "${PERIPHERY_LOGS}" | grep -iE "error|unauthorized|refused|failed" | tail -5 | sed 's/^/    /'
        echo "     Verifiez : adresse du Core, nom du Server dans l'UI Komodo, onboarding key."
    fi
else
    echo "  -> Connexion au Core : OK (pas d'erreur detectee)"
fi

echo ""
docker compose ps

echo ""
echo "==========================================="
echo "  Komodo Periphery installe et demarre"
echo "==========================================="
echo "{\"status\":\"ok\",\"server_name\":\"${KOMODO_SERVER_NAME}\",\"core_address\":\"${KOMODO_ADDRESS}\",\"core_reachable\":${CORE_OK},\"onboarding_key_used\":$([ -n "${KOMODO_ONBOARDING_KEY}" ] && echo true || echo false),\"root_directory\":\"${PERIPHERY_ROOT_DIRECTORY}\",\"strict_checks\":${STRICT_CHECKS}}"
