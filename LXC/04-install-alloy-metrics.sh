#!/bin/bash
###############################################################################
# Script 04 : Installation Grafana Alloy metriques (host + containers Docker)
#
# A executer DANS le container LXC ou la VM (en tant que root).
#
# Detecte automatiquement la presence de Docker :
#   - Si Docker present  -> deploiement via docker-compose (image grafana/alloy,
#                           node exporter + cadvisor embarques)
#   - Si Docker absent   -> installation paquet Debian + service systemd
#                           (node exporter uniquement)
#
# Coexistence avec l'agent logs (03-install-alloy.sh) :
#   - Mode docker  : deux containers independants (agflow-alloy-agent sur le
#                    port 12345, agflow-alloy-metrics sur le port 12346)
#   - Mode systemd : un seul service alloy qui charge tous les fichiers
#                    *.alloy de /etc/alloy (CONFIG_FILE="/etc/alloy")
#
# Variables d'environnement requises :
#   PROM_URL  - endpoint remote_write, ex : http://192.168.10.116:9090/api/v1/write
#   HOSTNAME  - identifiant du host (label `host`), ex : lxc201
#
# Variables optionnelles :
#   MODULE=...          - label `module` attache aux metriques (ex : agflow). Defaut : none
#   ROLE=...            - label `role` attache aux metriques (ex : manager). Defaut : none
#   STRICT_CHECKS=1     - echec si l'endpoint remote_write est injoignable (defaut : 0)
#   ALLOY_SRC_DIR=...   - dossier source des fichiers (defaut : /tmp/alloy-metrics)
#   ALLOY_DST_DIR=...   - dossier d'installation (defaut : /opt/alloy-metrics)
#
# Pre-requis (mode docker) :
#   - ${ALLOY_SRC_DIR}/ contient :
#       * docker-compose-metrics.yml
#       * config-metrics.alloy
#       * config-metrics-nodocker.alloy
###############################################################################
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

PROM_URL="${PROM_URL:-}"
HOSTNAME_LABEL="${HOSTNAME:-$(hostname)}"
MODULE="${MODULE:-}"
ROLE="${ROLE:-}"
ALLOY_SRC_DIR="${ALLOY_SRC_DIR:-/tmp/alloy-metrics}"
ALLOY_DST_DIR="${ALLOY_DST_DIR:-/opt/alloy-metrics}"
STRICT_CHECKS="${STRICT_CHECKS:-0}"

echo "==========================================="
echo "  Installation Grafana Alloy (metriques)"
echo "==========================================="
echo "  HOSTNAME     : ${HOSTNAME_LABEL}"
echo "  MODULE       : ${MODULE:-none}"
echo "  ROLE         : ${ROLE:-none}"
echo "  PROM_URL     : ${PROM_URL}"
echo "  Source dir   : ${ALLOY_SRC_DIR}"
echo "  Target dir   : ${ALLOY_DST_DIR}"
echo "  Strict mode  : ${STRICT_CHECKS}"
echo ""

if [ -z "${PROM_URL}" ]; then
    echo "ERREUR : PROM_URL doit etre defini."
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERREUR : Ce script doit etre execute en tant que root."
    exit 1
fi

if [ ! -d "${ALLOY_SRC_DIR}" ]; then
    echo "ERREUR : Source dir ${ALLOY_SRC_DIR} introuvable."
    echo "         Copier les fichiers alloy-agent metriques dans ${ALLOY_SRC_DIR} avant d'executer."
    exit 1
fi

# ── Test connectivite remote_write (warning ou error selon STRICT_CHECKS) ────
echo "  Test de connectivite vers l'endpoint remote_write..."
PROM_BASE=$(echo "${PROM_URL}" | sed -E 's|(https?://[^/]+).*|\1|')

PROM_OK=0
if command -v curl &>/dev/null; then
    # Toute reponse HTTP (meme 404/405) prouve que le backend repond.
    if curl -s --max-time 5 -o /dev/null "${PROM_BASE}"; then
        PROM_OK=1
        echo "  -> Endpoint joignable : OK (${PROM_BASE})"
    fi
fi

if [ "${PROM_OK}" -eq 0 ]; then
    if [ "${STRICT_CHECKS}" -eq 1 ]; then
        echo "  -> ERREUR : endpoint injoignable sur ${PROM_BASE}"
        echo "             Mode strict actif (STRICT_CHECKS=1) : abandon."
        exit 1
    else
        echo "  -> ATTENTION : endpoint injoignable sur ${PROM_BASE}"
        echo "                Alloy demarrera quand meme et retentera de pousser."
        echo "                Pour echouer dans ce cas : STRICT_CHECKS=1"
    fi
fi
echo ""

# ── Detection Docker ─────────────────────────────────────────────────────────
HAS_DOCKER=0
if command -v docker &>/dev/null && [ -S /var/run/docker.sock ]; then
    HAS_DOCKER=1
    echo "  Docker detecte -> mode container (node exporter + cadvisor)"
else
    echo "  Docker absent -> mode binaire systemd (node exporter uniquement)"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# MODE DOCKER
# ══════════════════════════════════════════════════════════════════════════════
if [ "${HAS_DOCKER}" -eq 1 ]; then

    mkdir -p "${ALLOY_DST_DIR}"

    echo "[1/4] Copie des fichiers vers ${ALLOY_DST_DIR}..."
    cp "${ALLOY_SRC_DIR}/docker-compose-metrics.yml" "${ALLOY_DST_DIR}/docker-compose.yml"
    cp "${ALLOY_SRC_DIR}/config-metrics.alloy" "${ALLOY_DST_DIR}/"
    echo "  -> OK"

    echo "[2/4] Ecriture .env..."
    cat > "${ALLOY_DST_DIR}/.env" << EOF
PROM_URL=${PROM_URL}
HOSTNAME=${HOSTNAME_LABEL}
MODULE=${MODULE}
ROLE=${ROLE}
EOF
    echo "  -> ${ALLOY_DST_DIR}/.env"

    echo "[3/4] Demarrage du container Alloy metriques..."
    cd "${ALLOY_DST_DIR}"
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
        echo "  ERREUR : impossible de puller l'image Alloy apres 3 tentatives."
        exit 1
    fi
    docker compose up -d
    echo "  -> OK"

    echo "[4/4] Verification post-install..."
    sleep 4
    CONTAINER_STATE=$(docker inspect -f '{{.State.Status}}' agflow-alloy-metrics 2>/dev/null || echo "unknown")

    if echo "${CONTAINER_STATE}" | grep -qiE "running|up"; then
        echo "  -> Container Alloy metriques : OK (${CONTAINER_STATE})"
    else
        echo "  -> ERREUR : Container Alloy metriques n'est pas en running (etat : ${CONTAINER_STATE})"
        echo ""
        echo "  Logs des 20 dernieres lignes :"
        docker compose logs --tail 20 2>&1 | sed 's/^/    /'
        exit 1
    fi

    # Verifier les erreurs remote_write recentes
    sleep 2
    ALLOY_LOGS=$(docker compose logs --tail 50 2>/dev/null || echo "")
    if echo "${ALLOY_LOGS}" | grep -qi "error.*remote_write\|connection refused\|no route to host"; then
        if [ "${STRICT_CHECKS}" -eq 1 ]; then
            echo "  -> ERREUR : Alloy a des erreurs de push remote_write"
            echo "${ALLOY_LOGS}" | grep -iE "error|refused" | tail -5 | sed 's/^/    /'
            exit 1
        else
            echo "  -> ATTENTION : Alloy a des erreurs de push remote_write (continue, retry auto)"
            echo "${ALLOY_LOGS}" | grep -iE "error|refused" | tail -5 | sed 's/^/    /'
        fi
    else
        echo "  -> Alloy push remote_write : OK (pas d'erreur detectee)"
    fi

    echo ""
    docker compose ps

# ══════════════════════════════════════════════════════════════════════════════
# MODE BINAIRE SYSTEMD
# ══════════════════════════════════════════════════════════════════════════════
else

    echo "[1/5] Ajout du depot Grafana..."
    if ! command -v wget &>/dev/null || ! command -v gpg &>/dev/null; then
        apt-get update -qq
        apt-get "${APT_OPTS[@]}" install -y -qq wget gnupg ca-certificates
    fi
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/grafana.gpg ] || [ ! -s /etc/apt/keyrings/grafana.gpg ]; then
        wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
        chmod a+r /etc/apt/keyrings/grafana.gpg
    fi
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    echo "  -> OK"

    echo "[2/5] Installation paquet alloy..."
    apt-get "${APT_OPTS[@]}" install -y -qq alloy
    echo "  -> OK"

    echo "[3/5] Ecriture config et environment..."
    # Config metriques dans son propre fichier : Alloy charge tous les
    # *.alloy de /etc/alloy (coexistence avec l'agent logs, cf. en-tete).
    cp "${ALLOY_SRC_DIR}/config-metrics-nodocker.alloy" /etc/alloy/metrics.alloy

    # Mise a jour idempotente de /etc/default/alloy : on ne remplace que nos
    # clefs pour ne pas ecraser celles de l'agent logs (LOKI_URL, ...).
    ensure_default_var() {
        local key="$1" val="$2"
        touch /etc/default/alloy
        if grep -q "^${key}=" /etc/default/alloy; then
            sed -i "s|^${key}=.*|${key}=${val}|" /etc/default/alloy
        else
            echo "${key}=${val}" >> /etc/default/alloy
        fi
    }
    ensure_default_var CONFIG_FILE '"/etc/alloy"'
    ensure_default_var CUSTOM_ARGS '""'
    ensure_default_var RESTART_ON_UPGRADE "true"
    ensure_default_var PROM_URL "${PROM_URL}"
    ensure_default_var HOSTNAME "${HOSTNAME_LABEL}"
    ensure_default_var MODULE "${MODULE}"
    ensure_default_var ROLE "${ROLE}"
    echo "  -> /etc/alloy/metrics.alloy"
    echo "  -> /etc/default/alloy (CONFIG_FILE=/etc/alloy)"

    echo "[4/5] Demarrage service alloy..."
    systemctl daemon-reload
    systemctl enable alloy
    systemctl restart alloy
    sleep 3
    echo "  -> OK"

    echo "[5/5] Verification post-install..."
    if systemctl is-active --quiet alloy; then
        echo "  -> Service alloy : OK (active)"
    else
        echo "  -> ERREUR : Service alloy n'est pas actif"
        systemctl status alloy --no-pager --lines=10 || true
        exit 1
    fi

    sleep 2
    JOURNAL_LOGS=$(journalctl -u alloy --since "30 seconds ago" --no-pager 2>/dev/null || echo "")
    if echo "${JOURNAL_LOGS}" | grep -qi "error.*remote_write\|connection refused\|no route to host"; then
        if [ "${STRICT_CHECKS}" -eq 1 ]; then
            echo "  -> ERREUR : Alloy a des erreurs de push remote_write"
            echo "${JOURNAL_LOGS}" | grep -iE "error|refused" | tail -5 | sed 's/^/    /'
            exit 1
        else
            echo "  -> ATTENTION : Alloy a des erreurs de push remote_write (continue, retry auto)"
            echo "${JOURNAL_LOGS}" | grep -iE "error|refused" | tail -5 | sed 's/^/    /'
        fi
    else
        echo "  -> Alloy push remote_write : OK (pas d'erreur detectee)"
    fi

    systemctl status alloy --no-pager --lines=5 || true
fi

echo ""
echo "==========================================="
echo "  Alloy metriques installe et demarre"
echo "==========================================="
echo "{\"status\":\"ok\",\"hostname\":\"${HOSTNAME_LABEL}\",\"module\":\"${MODULE}\",\"role\":\"${ROLE}\",\"prom_url\":\"${PROM_URL}\",\"prom_reachable\":${PROM_OK},\"strict_checks\":${STRICT_CHECKS},\"mode\":\"$([ ${HAS_DOCKER} -eq 1 ] && echo docker || echo systemd)\"}"
