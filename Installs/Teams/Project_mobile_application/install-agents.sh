#!/bin/bash
# install-agents.sh
# Configure les 8 agents OpenClaw pour le projet coaching sportif mobile
# bash -c "$(wget -qLO - https://github.com/Configurations/Proxmox/raw/main/Installs/Teams/Project_mobile_application/install-agents.sh)"

set -e

OPENCLAW_DIR="/root/.openclaw"
PROMPTS_DIR="$OPENCLAW_DIR/prompts"
SHARED_DIR="$OPENCLAW_DIR/workspace-shared"
OPENCLAW_JSON="$OPENCLAW_DIR/openclaw.json"
OPENCLAW_SECRETS="$OPENCLAW_DIR/.secrets"
BASE_URL="https://raw.githubusercontent.com/Configurations/Proxmox/refs/heads/main/Installs/Teams/Project_mobile_application"

echo "🔧 Installation des agents OpenClaw — Projet Mobile"
echo ""

# ── Vérification prérequis ────────────────────────────────────────────────────
if [ ! -f "$OPENCLAW_JSON" ]; then
  echo "❌ $OPENCLAW_JSON introuvable — lance openclaw.sh en premier"
  exit 1
fi

# ── 1. Récupérer le mot de passe dashboard depuis .secrets ───────────────────
# .secrets est écrit par openclaw.sh à partir du mot de passe root du container ($PASSWORD)
echo "🔑 Récupération des credentials..."

DASHBOARD_PASSWORD=""
if [ -f "$OPENCLAW_SECRETS" ]; then
  DASHBOARD_PASSWORD=$(grep '^DASHBOARD_PASSWORD=' "$OPENCLAW_SECRETS" | cut -d= -f2-)
  if [ -n "$DASHBOARD_PASSWORD" ]; then
    echo "  ✅ Mot de passe récupéré depuis .secrets"
  fi
fi

# Fallback si lancé manuellement sans openclaw.sh
if [ -z "$DASHBOARD_PASSWORD" ]; then
  echo "  ⚠️  .secrets introuvable — génération d'un nouveau mot de passe"
  DASHBOARD_PASSWORD=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 16)
  echo "DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}" > "$OPENCLAW_SECRETS"
  chmod 600 "$OPENCLAW_SECRETS"
  echo "  ✅ Nouveau mot de passe stocké dans .secrets"
fi

# ── 2. Créer les workspaces ───────────────────────────────────────────────────
echo "📁 Création des workspaces..."
mkdir -p "$PROMPTS_DIR"
mkdir -p "$SHARED_DIR/marketing/copy"
for ws in orchestrator strategist ux product python flutter marketing sysadmin; do
  mkdir -p "$OPENCLAW_DIR/workspace-$ws"
done
echo "  ✅ Workspaces créés"

# ── 3. Télécharger les system prompts ────────────────────────────────────────
echo "📝 Téléchargement des system prompts..."
for agent in orchestrator strategist ux-researcher product dev-python dev-flutter marketer sysadmin; do
  if wget -qO "$PROMPTS_DIR/$agent.md" "$BASE_URL/prompts/$agent.md" 2>/dev/null; then
    echo "  ✅ $agent.md"
  else
    echo "  ⚠️  $agent.md introuvable sur le repo"
  fi
done

# ── 4. Fusion dans openclaw.json ─────────────────────────────────────────────
echo "⚙️  Fusion de la config agents dans openclaw.json..."
cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.pre-agents.bak"
echo "  📦 Backup : openclaw.json.pre-agents.bak"

DASHBOARD_PASSWORD="$DASHBOARD_PASSWORD" node << 'NODEJS'
const fs  = require('fs');
const p   = '/root/.openclaw/openclaw.json';
const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
const pwd = process.env.DASHBOARD_PASSWORD;

// Gateway
if (!cfg.gateway) cfg.gateway = {};
cfg.gateway.mode = 'local';
cfg.gateway.auth = { mode: 'password', password: pwd };

// Agents
if (!cfg.agents) cfg.agents = {};
if (!cfg.agents.defaults) cfg.agents.defaults = {};
cfg.agents.defaults.workspace = '/root/.openclaw/workspace';

cfg.agents.list = [
  { id: 'orchestrator',  name: 'Orchestrator',   model: 'claude-opus-4-6',  default: true,
    workspace: '/root/.openclaw/workspace-orchestrator' },
  { id: 'strategist',    name: 'Strategist',      model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-strategist' },
  { id: 'ux-researcher', name: 'UX Researcher',   model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-ux' },
  { id: 'product',       name: 'Product Manager', model: 'claude-opus-4-6',
    workspace: '/root/.openclaw/workspace-product' },
  { id: 'dev-python',    name: 'Dev Backend',     model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-python' },
  { id: 'dev-flutter',   name: 'Dev Mobile',      model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-flutter' },
  { id: 'marketer',      name: 'Marketer',        model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-marketing' },
  { id: 'sysadmin',      name: 'Sysadmin',        model: 'claude-sonnet-4-6',
    workspace: '/root/.openclaw/workspace-sysadmin' }
];

// Bindings — slackChannel rejeté par cette version, on bind par channel uniquement
// La distinction par channel Slack se configure via `openclaw onboard` après installation
cfg.bindings = [
  { agentId: 'orchestrator', match: { channel: 'telegram' } },
  { agentId: 'orchestrator', match: { channel: 'slack' } }
];

fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
console.log('  ✅ openclaw.json fusionné avec succès');
NODEJS

# ── 5. Workspace partagé ──────────────────────────────────────────────────────
echo "📋 Initialisation du workspace partagé..."

if [ ! -f "$SHARED_DIR/changelog.md" ]; then
  cat > "$SHARED_DIR/changelog.md" << 'EOF'
# Changelog — Workspace Partagé

Format : [YYYY-MM-DD HH:MM] agent — action effectuée

---
EOF
  echo "  ✅ changelog.md initialisé"
fi

if [ ! -f "$SHARED_DIR/decisions.md" ]; then
  cat > "$SHARED_DIR/decisions.md" << 'EOF'
# Décisions Produit

| Date | Décision | Raison | Auteur |
|------|----------|--------|--------|
EOF
  echo "  ✅ decisions.md initialisé"
fi

# ── 6. Redémarrage ───────────────────────────────────────────────────────────
echo ""
echo "🔄 Redémarrage OpenClaw..."
systemctl restart openclaw-gateway
sleep 3
systemctl is-active openclaw-gateway \
  && echo "  ✅ OpenClaw Gateway actif" \
  || echo "  ⚠️  Service non actif — vérifier : journalctl -u openclaw-gateway -n 20"

# ── 7. Résumé ─────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Agents installés !"
echo ""
echo "  Agents configurés :"
node -e "
  const cfg = JSON.parse(require('fs').readFileSync('/root/.openclaw/openclaw.json','utf8'));
  (cfg.agents.list || []).forEach(a => console.log('    ✅', a.id, '—', a.model));
"
echo ""
echo "  📣 Channels Slack à créer :"
echo "     #general            → orchestrator"
echo "     #strategist-veille  → strategist"
echo "     #ux-research        → ux-researcher"
echo "     #product-backlog    → product"
echo "     #dev-backend        → dev-python"
echo "     #dev-mobile         → dev-flutter"
echo "     #marketing          → marketer"
echo "     #sysadmin-ops       → sysadmin"
echo ""
echo "  🔒 Dashboard via tunnel SSH (Windows PowerShell) :"
echo "     ssh -L 18789:127.0.0.1:18789 root@${IP} -N"
echo "     Puis : http://127.0.0.1:18789"
echo "     Mot de passe dashboard : ${DASHBOARD_PASSWORD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"