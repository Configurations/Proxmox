#!/bin/bash
###############################################################################
# Deploiement Alloy collecteur sur tous les LXC actifs du homelab.
#
# A executer depuis le poste local (Windows / Linux), depuis la racine du repo
# Configurations/Proxmox. Utilise le host Proxmox (alias SSH `pve`) comme
# bastion :
#   - pct push <CTID> ... pour copier les fichiers
#   - pct exec <CTID> -- bash ... pour executer le script d'installation
#
# Variables :
#   LOKI_URL  - endpoint Loki central. Si non defini, auto-detecte depuis le
#               LXC 116 (qui heberge Loki/Grafana).
#   LXC_HOSTS - liste d'IDs LXC a deployer. Defaut : tous les LXC actifs.
#   PVE_HOST  - alias SSH du host Proxmox, defaut `pve`.
#   LOKI_LXC  - CTID du LXC qui heberge Loki, defaut 116.
#   LOKI_PORT - port Loki, defaut 3100.
#
# Usage standard (auto-detect Loki) :
#   ./deploy-alloy-all.sh
#
# Usage avec URL Loki explicite :
#   LOKI_URL="http://192.168.10.110:3100/loki/api/v1/push" ./deploy-alloy-all.sh
#
# Usage sur un sous-ensemble :
#   LXC_HOSTS="201 102" ./deploy-alloy-all.sh
#
# Cas special : sur le LXC qui heberge Loki (116 par defaut), Alloy utilise
# automatiquement http://localhost:3100/loki/api/v1/push pour eviter un
# aller-retour reseau et casser la dependance circulaire.
###############################################################################
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOY_AGENT_DIR="${REPO_DIR}/alloy-agent"
INSTALL_SCRIPT="${REPO_DIR}/03-install-alloy.sh"

PVE_HOST="${PVE_HOST:-pve}"
LOKI_LXC="${LOKI_LXC:-116}"
LOKI_PORT="${LOKI_PORT:-3100}"

# Liste mise a jour : LXC actifs + ajout du 300 (manager Swarm),
# retrait des 111 et 114 qui n'existent plus.
LXC_HOSTS="${LXC_HOSTS:-101 102 108 112 113 115 116 117 201 300}"

# ── Auto-detect Loki URL si non fournie ──────────────────────────────────────
if [ -z "${LOKI_URL:-}" ]; then
    echo "  -> LOKI_URL non definie, auto-detection depuis LXC ${LOKI_LXC}..."
    LOKI_IP=$(ssh "${PVE_HOST}" "pct exec ${LOKI_LXC} -- bash -c \"hostname -I | awk '{print \\\$1}'\"" 2>/dev/null || echo "")
    if [ -z "${LOKI_IP}" ]; then
        echo "ERREUR : impossible de detecter l'IP du LXC ${LOKI_LXC} (Loki)."
        echo "         Verifiez que le LXC tourne, ou forcez via :"
        echo "         LOKI_URL=\"http://<IP>:${LOKI_PORT}/loki/api/v1/push\" $0"
        exit 1
    fi
    LOKI_URL="http://${LOKI_IP}:${LOKI_PORT}/loki/api/v1/push"
    echo "  -> Loki detecte : ${LOKI_IP} -> ${LOKI_URL}"
fi

# ── Verifications de pre-requis ──────────────────────────────────────────────
if [ ! -d "${ALLOY_AGENT_DIR}" ]; then
    echo "ERREUR : ${ALLOY_AGENT_DIR} introuvable."
    echo "         Le script doit etre lance depuis le dossier LXC/ du repo."
    exit 1
fi

if [ ! -f "${INSTALL_SCRIPT}" ]; then
    echo "ERREUR : ${INSTALL_SCRIPT} introuvable."
    exit 1
fi

for f in config.alloy config-journald-only.alloy docker-compose.yml; do
    if [ ! -f "${ALLOY_AGENT_DIR}/${f}" ]; then
        echo "ERREUR : ${ALLOY_AGENT_DIR}/${f} introuvable."
        exit 1
    fi
done

echo "==========================================="
echo "  Deploiement Alloy collecteur"
echo "==========================================="
echo "  PVE_HOST    : ${PVE_HOST}"
echo "  LOKI_URL    : ${LOKI_URL}"
echo "  LOKI_LXC    : ${LOKI_LXC} (cas special : utilise localhost)"
echo "  LXC_HOSTS   : ${LXC_HOSTS}"
echo "  ALLOY_DIR   : ${ALLOY_AGENT_DIR}"
echo "  INSTALL     : ${INSTALL_SCRIPT}"
echo ""

FAILED=()
SUCCESS=()
SKIPPED=()

for CTID in ${LXC_HOSTS}; do
    HOSTNAME_LABEL="lxc${CTID}"
    echo "──────────────────────────────────────────"
    echo "  LXC ${CTID} (${HOSTNAME_LABEL})"
    echo "──────────────────────────────────────────"

    # Verifier que le LXC est running
    STATUS=$(ssh "${PVE_HOST}" "pct status ${CTID} 2>/dev/null || echo absent")
    if ! echo "${STATUS}" | grep -q "running"; then
        echo "  [!] LXC ${CTID} status = ${STATUS} -> skip"
        SKIPPED+=("${CTID}:${STATUS}")
        continue
    fi

    # Cas special : si CTID = LOKI_LXC, utiliser localhost pour eviter
    # l'aller-retour reseau et la dependance circulaire.
    if [ "${CTID}" = "${LOKI_LXC}" ]; then
        EFFECTIVE_LOKI_URL="http://localhost:${LOKI_PORT}/loki/api/v1/push"
        echo "  [i] LXC ${CTID} heberge Loki -> utilise ${EFFECTIVE_LOKI_URL}"
    else
        EFFECTIVE_LOKI_URL="${LOKI_URL}"
    fi

    # Preparer le dossier source dans le LXC
    if ! ssh "${PVE_HOST}" "pct exec ${CTID} -- bash -c 'rm -rf /tmp/alloy-agent && mkdir -p /tmp/alloy-agent'"; then
        echo "  [!] Impossible de preparer /tmp/alloy-agent dans LXC ${CTID}"
        FAILED+=("${CTID}:mkdir-failed")
        continue
    fi

    # Pousser les fichiers via pct push
    echo "  [1/3] Copie des fichiers..."
    PUSH_OK=1
    for FILE in config.alloy config-journald-only.alloy docker-compose.yml; do
        if ! scp -q "${ALLOY_AGENT_DIR}/${FILE}" "${PVE_HOST}:/tmp/alloy-${CTID}-${FILE}"; then
            echo "  [!] Echec scp ${FILE}"
            PUSH_OK=0
            break
        fi
        if ! ssh "${PVE_HOST}" "pct push ${CTID} /tmp/alloy-${CTID}-${FILE} /tmp/alloy-agent/${FILE} && rm /tmp/alloy-${CTID}-${FILE}"; then
            echo "  [!] Echec pct push ${FILE}"
            PUSH_OK=0
            break
        fi
    done

    if [ "${PUSH_OK}" -eq 0 ]; then
        FAILED+=("${CTID}:push-failed")
        continue
    fi

    # Pousser le script d'install
    if ! scp -q "${INSTALL_SCRIPT}" "${PVE_HOST}:/tmp/03-install-alloy-${CTID}.sh"; then
        echo "  [!] Echec scp 03-install-alloy.sh"
        FAILED+=("${CTID}:script-push-failed")
        continue
    fi
    ssh "${PVE_HOST}" "pct push ${CTID} /tmp/03-install-alloy-${CTID}.sh /tmp/03-install-alloy.sh && rm /tmp/03-install-alloy-${CTID}.sh"
    ssh "${PVE_HOST}" "pct exec ${CTID} -- chmod +x /tmp/03-install-alloy.sh"
    echo "  -> OK"

    # Lancer l'installation
    echo "  [2/3] Execution 03-install-alloy.sh..."
    if ssh "${PVE_HOST}" "pct exec ${CTID} -- env LOKI_URL='${EFFECTIVE_LOKI_URL}' HOSTNAME='${HOSTNAME_LABEL}' bash /tmp/03-install-alloy.sh"; then
        echo "  -> OK"
    else
        echo "  [!] Echec installation sur LXC ${CTID}"
        FAILED+=("${CTID}:install-failed")
        continue
    fi

    echo "  [3/3] LXC ${CTID} -> Alloy actif"
    SUCCESS+=("${CTID}")
    echo ""
done

# ── Resume final ─────────────────────────────────────────────────────────────
echo "==========================================="
echo "  Resume du deploiement"
echo "==========================================="
echo "  Reussis  (${#SUCCESS[@]}) : ${SUCCESS[*]:-aucun}"
echo "  Skippes  (${#SKIPPED[@]}) : ${SKIPPED[*]:-aucun}"
echo "  Echoues  (${#FAILED[@]})  : ${FAILED[*]:-aucun}"
echo ""

if [ ${#FAILED[@]} -ne 0 ]; then
    exit 1
fi
exit 0
