#!/bin/bash
###############################################################################
# Deploiement Alloy collecteur sur tous les LXC actifs du homelab.
#
# A executer SUR L'HOTE PROXMOX (pas depuis un poste local).
#
# Usage :
#   bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/LXC/deploy-alloy-all.sh)"
#
# Le script telecharge automatiquement les fichiers necessaires depuis GitHub
# vers /tmp/alloy-files/, puis les pousse sur chaque LXC via pct push +
# lance l'installation via pct exec.
#
# Variables d'environnement :
#   LOKI_URL       Endpoint Loki. Auto-detecte depuis le LXC 116 si non defini.
#   LXC_HOSTS      Liste de CTID a traiter. Defaut : tous les LXC actifs avec Docker.
#   LOKI_LXC       CTID du LXC qui heberge Loki. Defaut : 116.
#   LOKI_PORT      Port Loki. Defaut : 3100.
#   STRICT_CHECKS  Si 1, echoue si Loki injoignable depuis un LXC. Defaut : 0.
#   REPO_BRANCH    Branche GitHub a utiliser. Defaut : main.
#
# Cas special : sur le LXC qui heberge Loki (116), Alloy utilise
# automatiquement http://localhost:3100 pour eviter un aller-retour reseau
# et casser la dependance circulaire.
###############################################################################
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_URL="https://github.com/Configurations/Proxmox/raw/${REPO_BRANCH}/LXC"

LOKI_LXC="${LOKI_LXC:-116}"
LOKI_PORT="${LOKI_PORT:-3100}"
STRICT_CHECKS="${STRICT_CHECKS:-0}"

# Repertoire temporaire sur l'hote Proxmox pour telecharger les fichiers
WORK_DIR="${WORK_DIR:-/tmp/alloy-files}"

# Liste par defaut : LXC actifs sans le 117 (vault stoppe). Ajustable via LXC_HOSTS.
DEFAULT_LXC_LIST="101 102 108 112 113 115 116 201 300"

# ── Verifications de pre-requis ──────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "ERREUR : Ce script doit etre execute en tant que root sur l'hote Proxmox."
    exit 1
fi

if ! command -v pct &>/dev/null; then
    echo "ERREUR : commande 'pct' introuvable."
    echo "        Ce script doit s'executer sur un hote Proxmox VE."
    exit 1
fi

if ! command -v wget &>/dev/null; then
    echo "ERREUR : wget requis mais introuvable."
    exit 1
fi

echo "==========================================="
echo "  Deploiement Alloy collecteur"
echo "==========================================="
echo ""

# ── Telechargement des fichiers depuis GitHub ────────────────────────────────
echo "[1/4] Telechargement des fichiers depuis GitHub..."
echo "      Branche : ${REPO_BRANCH}"
mkdir -p "${WORK_DIR}"

FILES_TO_FETCH=(
    "03-install-alloy.sh"
    "alloy-agent/config.alloy"
    "alloy-agent/config-journald-only.alloy"
    "alloy-agent/docker-compose.yml"
)

for file in "${FILES_TO_FETCH[@]}"; do
    url="${RAW_URL}/${file}"
    dest="${WORK_DIR}/$(basename "${file}")"
    echo "  -> ${file}"
    if ! wget -qLO "${dest}" "${url}"; then
        echo "  ERREUR : echec telechargement ${url}"
        exit 1
    fi
    if [ ! -s "${dest}" ]; then
        echo "  ERREUR : fichier ${dest} vide apres telechargement."
        exit 1
    fi
done

chmod +x "${WORK_DIR}/03-install-alloy.sh"
echo "  -> OK"
echo ""

# ── Auto-detection de l'IP Loki ──────────────────────────────────────────────
echo "[2/4] Detection de l'IP Loki..."

if [ -z "${LOKI_URL:-}" ]; then
    if ! pct status "${LOKI_LXC}" &>/dev/null; then
        echo "  ERREUR : LXC ${LOKI_LXC} (Loki) introuvable."
        echo "          Forcez l'URL : LOKI_URL=\"http://<IP>:${LOKI_PORT}/loki/api/v1/push\""
        exit 1
    fi

    if ! pct status "${LOKI_LXC}" | grep -q running; then
        echo "  ERREUR : LXC ${LOKI_LXC} (Loki) n'est pas en cours d'execution."
        exit 1
    fi

    LOKI_IP=$(pct exec "${LOKI_LXC}" -- bash -c "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "")
    if [ -z "${LOKI_IP}" ]; then
        echo "  ERREUR : impossible de detecter l'IP du LXC ${LOKI_LXC}."
        exit 1
    fi
    LOKI_URL="http://${LOKI_IP}:${LOKI_PORT}/loki/api/v1/push"
    echo "  -> Loki detecte sur LXC ${LOKI_LXC} : ${LOKI_IP}"
else
    echo "  -> URL forcee via env : ${LOKI_URL}"
fi
echo ""

# ── Determiner la liste des LXC ──────────────────────────────────────────────
LXC_HOSTS="${LXC_HOSTS:-${DEFAULT_LXC_LIST}}"
echo "[3/4] LXC cibles : ${LXC_HOSTS}"
echo ""

# ── Boucle de deploiement ────────────────────────────────────────────────────
echo "[4/4] Deploiement..."
echo ""

FAILED=()
SUCCESS=()
SKIPPED=()

for CTID in ${LXC_HOSTS}; do
    HOSTNAME_LABEL="lxc${CTID}"
    echo "──────────────────────────────────────────"
    echo "  LXC ${CTID} (${HOSTNAME_LABEL})"
    echo "──────────────────────────────────────────"

    # Verifier que le LXC existe et tourne
    if ! pct status "${CTID}" &>/dev/null; then
        echo "  [!] LXC ${CTID} n'existe pas -> skip"
        SKIPPED+=("${CTID}:absent")
        continue
    fi
    if ! pct status "${CTID}" | grep -q running; then
        echo "  [!] LXC ${CTID} n'est pas running -> skip"
        SKIPPED+=("${CTID}:stopped")
        continue
    fi

    # Cas special : si CTID = LOKI_LXC, utiliser localhost
    if [ "${CTID}" = "${LOKI_LXC}" ]; then
        EFFECTIVE_LOKI_URL="http://localhost:${LOKI_PORT}/loki/api/v1/push"
        echo "  [i] LXC ${CTID} heberge Loki -> utilise ${EFFECTIVE_LOKI_URL}"
    else
        EFFECTIVE_LOKI_URL="${LOKI_URL}"
    fi

    # Preparer le dossier source dans le LXC
    if ! pct exec "${CTID}" -- bash -c "rm -rf /tmp/alloy-agent && mkdir -p /tmp/alloy-agent" 2>/dev/null; then
        echo "  [!] Impossible de preparer /tmp/alloy-agent dans LXC ${CTID}"
        FAILED+=("${CTID}:mkdir-failed")
        continue
    fi

    # Pousser les fichiers Alloy
    echo "  [1/3] Copie des fichiers Alloy..."
    PUSH_OK=1
    for FILE in config.alloy config-journald-only.alloy docker-compose.yml; do
        if ! pct push "${CTID}" "${WORK_DIR}/${FILE}" "/tmp/alloy-agent/${FILE}" 2>/dev/null; then
            echo "  [!] Echec pct push ${FILE}"
            PUSH_OK=0
            break
        fi
    done

    if [ "${PUSH_OK}" -eq 0 ]; then
        FAILED+=("${CTID}:push-failed")
        continue
    fi

    # Pousser le script d'installation
    if ! pct push "${CTID}" "${WORK_DIR}/03-install-alloy.sh" /tmp/03-install-alloy.sh 2>/dev/null; then
        echo "  [!] Echec pct push 03-install-alloy.sh"
        FAILED+=("${CTID}:script-push-failed")
        continue
    fi
    pct exec "${CTID}" -- chmod +x /tmp/03-install-alloy.sh
    echo "  -> OK"

    # Lancer l'installation
    echo "  [2/3] Execution 03-install-alloy.sh..."
    if pct exec "${CTID}" -- env \
        LOKI_URL="${EFFECTIVE_LOKI_URL}" \
        HOSTNAME="${HOSTNAME_LABEL}" \
        STRICT_CHECKS="${STRICT_CHECKS}" \
        bash /tmp/03-install-alloy.sh; then
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
echo ""
echo "==========================================="
echo "  Resume du deploiement"
echo "==========================================="
echo "  Reussis  (${#SUCCESS[@]}) : ${SUCCESS[*]:-aucun}"
echo "  Skippes  (${#SKIPPED[@]}) : ${SKIPPED[*]:-aucun}"
echo "  Echoues  (${#FAILED[@]})  : ${FAILED[*]:-aucun}"
echo ""

# Nettoyage du dossier temporaire (optionnel, garde si echec pour debug)
if [ "${#FAILED[@]}" -eq 0 ]; then
    rm -rf "${WORK_DIR}"
    echo "  Dossier temporaire ${WORK_DIR} nettoye."
else
    echo "  Dossier temporaire ${WORK_DIR} conserve pour debug."
fi
echo ""

if [ ${#FAILED[@]} -ne 0 ]; then
    exit 1
fi
exit 0
