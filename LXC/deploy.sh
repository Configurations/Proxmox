#!/bin/bash
###############################################################################
# Script de déploiement ag.flow vers LXC 203 (via host pve comme bastion).
#
# Pré-requis :
#   - SSH alias `pve` configuré (~/.ssh/config)
#   - Sur pve : clef SSH du LXC 203 dans /root/.ssh/lxc-keys/id_ed25519_lxc203
#   - Sur la machine locale : node + npm pour build du frontend, uv pour build backend
#   - Fichier infra/.env.deploy local (gitignored) avec :
#       KEYCLOAK_CLIENT_SECRET=...   (à fournir manuellement)
#       (optionnel) SESSION_COOKIE_SECRET, POSTGRES_PASSWORD : générés auto si absents
#
# Workflow :
#   1. Build frontend dist localement
#   2. Rsync repo vers pve:/tmp/agflow-deploy/
#   3. Rsync depuis pve vers LXC 203 /opt/agflow/
#   4. Sur LXC 203 : génère .env.prod si absent, copie Caddyfile, docker compose up -d --build
#   5. Reload Caddy host
###############################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LXC_IP="192.168.10.84"
LXC_KEY="/root/.ssh/lxc-keys/id_ed25519_lxc203"
DEPLOY_USER="root"
DEPLOY_DIR="/opt/agflow"
PVE_STAGE="/tmp/agflow-deploy"

ENV_DEPLOY="${REPO_ROOT}/infra/.env.deploy"

# ─── Pré-vérifications ──────────────────────────────────────────────────────
if [ ! -f "${ENV_DEPLOY}" ]; then
    echo "ERREUR : ${ENV_DEPLOY} introuvable."
    echo ""
    echo "Créer le fichier avec au minimum :"
    echo "  KEYCLOAK_CLIENT_SECRET=<secret depuis Keycloak admin>"
    echo ""
    echo "Optionnel (sinon générés auto) :"
    echo "  SESSION_COOKIE_SECRET=..."
    echo "  POSTGRES_PASSWORD=..."
    exit 1
fi

# shellcheck disable=SC1090
source "${ENV_DEPLOY}"

if [ -z "${KEYCLOAK_CLIENT_SECRET:-}" ]; then
    echo "ERREUR : KEYCLOAK_CLIENT_SECRET vide dans ${ENV_DEPLOY}"
    exit 1
fi

echo "==========================================="
echo "  Déploiement ag.flow → LXC 203 (${LXC_IP})"
echo "==========================================="
echo ""

# ─── 1. Build frontend localement ───────────────────────────────────────────
echo "[1/5] Build frontend (npm run build)..."
cd "${REPO_ROOT}/frontend"
if [ ! -d node_modules ]; then
    npm ci
fi
npm run build
cd "${REPO_ROOT}"
echo "  -> dist généré : $(du -sh frontend/dist | cut -f1)"

# ─── 2. Transfert repo vers pve (tar over ssh — pas besoin de rsync local) ──
echo "[2/5] Transfert repo (tar over ssh) vers pve:${PVE_STAGE}..."
ssh pve "rm -rf ${PVE_STAGE} && mkdir -p ${PVE_STAGE}"

# tar local → ssh pve → untar. Frontend/dist inclus (déjà buildé), node_modules / .venv exclus.
tar -czf - \
    --exclude='./.git' \
    --exclude='./node_modules' \
    --exclude='**/node_modules' \
    --exclude='./.venv' \
    --exclude='**/.venv' \
    --exclude='./__pycache__' \
    --exclude='**/__pycache__' \
    --exclude='*.pyc' \
    --exclude='./.pytest_cache' \
    --exclude='./.ruff_cache' \
    --exclude='./meta-model/typescript/dist' \
    --exclude='./frontend/dist-types' \
    --exclude='./.env' \
    --exclude='**/.env.local' \
    --exclude='./.env.prod' \
    --exclude='./infra/.env.deploy' \
    -C "${REPO_ROOT}" \
    . | ssh pve "tar -xzf - -C ${PVE_STAGE}"

echo "  -> transfert terminé : $(ssh pve "du -sh ${PVE_STAGE} | cut -f1")"

# ─── 3. Rsync depuis pve vers LXC 203 ──────────────────────────────────────
echo "[3/5] Rsync pve → LXC 203:${DEPLOY_DIR}..."
ssh pve "ssh -i ${LXC_KEY} -o StrictHostKeyChecking=no ${DEPLOY_USER}@${LXC_IP} 'mkdir -p ${DEPLOY_DIR}'"
ssh pve "rsync -avz --delete --exclude='.env.prod' --exclude='data/' -e 'ssh -i ${LXC_KEY} -o StrictHostKeyChecking=no' ${PVE_STAGE}/ ${DEPLOY_USER}@${LXC_IP}:${DEPLOY_DIR}/"
echo "  -> rsync LXC OK"

# ─── 4. Génération .env.prod sur LXC + Caddyfile + docker compose ──────────
echo "[4/5] Configuration LXC + docker compose up..."

# Préparer le bloc .env.prod côté LXC : génération auto des secrets manquants
ssh pve "ssh -i ${LXC_KEY} -o StrictHostKeyChecking=no ${DEPLOY_USER}@${LXC_IP} bash -s" << REMOTE_SCRIPT
set -euo pipefail

cd ${DEPLOY_DIR}

# .env.prod : créé une seule fois (regénération = data loss côté Postgres)
if [ ! -f .env.prod ]; then
    echo "  -> Génération initiale de .env.prod"
    POSTGRES_PASSWORD=\$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    SESSION_COOKIE_SECRET=\$(openssl rand -hex 32)
    cat > .env.prod << EOF
POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
KEYCLOAK_ISSUER=https://security.yoops.org/realms/yoops
KEYCLOAK_CLIENT_ID=workflow-agflow
KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}
AGFLOW_PUBLIC_BASE_URL=https://workflow-agflow.yoops.org
SESSION_COOKIE_SECRET=\${SESSION_COOKIE_SECRET}
LOG_LEVEL=INFO
EOF
    chmod 600 .env.prod
    echo "  -> .env.prod créé (secrets générés)"
else
    echo "  -> .env.prod existant conservé (secrets préservés)"
    # Mettre à jour KEYCLOAK_CLIENT_SECRET si différent
    sed -i "s|^KEYCLOAK_CLIENT_SECRET=.*|KEYCLOAK_CLIENT_SECRET=${KEYCLOAK_CLIENT_SECRET}|" .env.prod
fi

# Copie le Caddyfile vers /etc/caddy puis reload
cp infra/Caddyfile.prod /etc/caddy/Caddyfile
systemctl reload caddy
echo "  -> Caddyfile installé + Caddy rechargé"

# Build & start (build forcé pour récupérer les changements de code)
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d --build
echo "  -> docker compose up -d --build terminé"

# Healthcheck
echo "  -> Attente du backend (healthcheck)..."
for i in {1..30}; do
    if curl -sf http://127.0.0.1:8000/health > /dev/null 2>&1; then
        echo "  -> Backend UP : \$(curl -s http://127.0.0.1:8000/health)"
        break
    fi
    if [ \$i -eq 30 ]; then
        echo "  -> ATTENTION : backend pas répondu après 30s"
        docker compose -f docker-compose.prod.yml logs --tail 30 backend
    fi
    sleep 1
done
REMOTE_SCRIPT

# ─── 5. Cleanup pve stage ──────────────────────────────────────────────────
echo "[5/5] Cleanup..."
ssh pve "rm -rf ${PVE_STAGE}"

echo ""
echo "==========================================="
echo "  Déploiement terminé"
echo "  → https://workflow-agflow.yoops.org"
echo "==========================================="
