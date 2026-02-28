#!/bin/bash
# install-agents.sh
# Configure tous les agents OpenClaw pour le projet coaching sportif
# À exécuter DANS le container LXC après l'installation openclaw.sh

set -e

# ── FIX 5 : chemins absolus — ~ non résolu dans certains contextes bash ───────
OPENCLAW_DIR="/root/.openclaw"
PROMPTS_DIR="$OPENCLAW_DIR/prompts"
SHARED_DIR="$OPENCLAW_DIR/workspace-shared"
OPENCLAW_JSON="$OPENCLAW_DIR/openclaw.json"
BASE_URL="https://raw.githubusercontent.com/Configurations/Proxmox/refs/heads/main/Installs/Teams/Project_mobile_application"

echo "🔧 Installation des agents OpenClaw..."

# ── 1. Créer les dossiers ──────────────────────────────────────────────────────
echo "📁 Création des workspaces..."
mkdir -p "$PROMPTS_DIR"
mkdir -p "$SHARED_DIR/marketing/copy"
mkdir -p "$OPENCLAW_DIR/workspace-orchestrator"
mkdir -p "$OPENCLAW_DIR/workspace-strategist"
mkdir -p "$OPENCLAW_DIR/workspace-ux"
mkdir -p "$OPENCLAW_DIR/workspace-product"
mkdir -p "$OPENCLAW_DIR/workspace-python"
mkdir -p "$OPENCLAW_DIR/workspace-flutter"
mkdir -p "$OPENCLAW_DIR/workspace-marketing"
mkdir -p "$OPENCLAW_DIR/workspace-sysadmin"
echo "  ✅ Workspaces créés"

# ── 2. Télécharger les system prompts ─────────────────────────────────────────
echo "📝 Téléchargement des system prompts..."
for agent in orchestrator strategist ux-researcher product dev-python dev-flutter marketer sysadmin; do
  wget -qO "$PROMPTS_DIR/$agent.md" "$BASE_URL/prompts/$agent.md" \
    && echo "  ✅ $agent.md" \
    || echo "  ⚠️  $agent.md introuvable sur $BASE_URL"
done

# ── 3. FIX PRINCIPAL : fusionner la config agents dans openclaw.json ──────────
# On ne remplace PAS openclaw.json — on y injecte nos clés (agents, bindings,
# browser, sharedWorkspace) tout en préservant les clés natives générées par
# openclaw setup (gateway.auth.token, compaction, wizard, meta...).
echo "⚙️  Fusion de la config agents dans openclaw.json..."

if [ ! -f "$OPENCLAW_JSON" ]; then
  echo "  ❌ $OPENCLAW_JSON introuvable — as-tu bien lancé openclaw.sh avant ?"
  exit 1
fi

# Backup avant fusion
cp "$OPENCLAW_JSON" "$OPENCLAW_JSON.pre-agents.bak"
echo "  📦 Backup créé : openclaw.json.pre-agents.bak"

# Fusion via Node.js — injecte nos clés sans toucher aux clés natives
node -e "
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync('$OPENCLAW_JSON', 'utf8'));

// Agents
if (!cfg.agents) cfg.agents = {};
if (!cfg.agents.defaults) cfg.agents.defaults = {};

// Préserver les defaults natifs (compaction, maxConcurrent...) et ajouter workspace
cfg.agents.defaults.workspace = '/root/.openclaw/workspace';

cfg.agents.list = [
  { id: 'orchestrator',  name: 'Orchestrator',    model: 'claude-opus-4-6',   default: true, workspace: '/root/.openclaw/workspace-orchestrator', systemPromptFile: '/root/.openclaw/prompts/orchestrator.md',  browser: { enabled: false } },
  { id: 'strategist',    name: 'Strategist',       model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-strategist',   systemPromptFile: '/root/.openclaw/prompts/strategist.md',    browser: { enabled: true  } },
  { id: 'ux-researcher', name: 'UX Researcher',    model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-ux',            systemPromptFile: '/root/.openclaw/prompts/ux-researcher.md', browser: { enabled: true  } },
  { id: 'product',       name: 'Product Manager',  model: 'claude-opus-4-6',   workspace: '/root/.openclaw/workspace-product',       systemPromptFile: '/root/.openclaw/prompts/product.md',       browser: { enabled: false } },
  { id: 'dev-python',    name: 'Dev Backend',      model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-python',        systemPromptFile: '/root/.openclaw/prompts/dev-python.md',    browser: { enabled: false } },
  { id: 'dev-flutter',   name: 'Dev Mobile',       model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-flutter',       systemPromptFile: '/root/.openclaw/prompts/dev-flutter.md',   browser: { enabled: false } },
  { id: 'marketer',      name: 'Marketer',         model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-marketing',     systemPromptFile: '/root/.openclaw/prompts/marketer.md',      browser: { enabled: true  } },
  { id: 'sysadmin',      name: 'Sysadmin',         model: 'claude-sonnet-4-6', workspace: '/root/.openclaw/workspace-sysadmin',      systemPromptFile: '/root/.openclaw/prompts/sysadmin.md',      browser: { enabled: false } }
];

// Bindings
cfg.bindings = [
  { agentId: 'orchestrator',  match: { channel: 'telegram' } },
  { agentId: 'orchestrator',  match: { channel: 'slack', slackChannel: '#general' } },
  { agentId: 'strategist',    match: { channel: 'slack', slackChannel: '#strategist-veille' } },
  { agentId: 'ux-researcher', match: { channel: 'slack', slackChannel: '#ux-research' } },
  { agentId: 'product',       match: { channel: 'slack', slackChannel: '#product-backlog' } },
  { agentId: 'dev-python',    match: { channel: 'slack', slackChannel: '#dev-backend' } },
  { agentId: 'dev-flutter',   match: { channel: 'slack', slackChannel: '#dev-mobile' } },
  { agentId: 'marketer',      match: { channel: 'slack', slackChannel: '#marketing' } },
  { agentId: 'sysadmin',      match: { channel: 'slack', slackChannel: '#sysadmin-ops' } }
];

// Browser (Playwright dans LXC sans sandbox)
cfg.browser = {
  chromiumFlags: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
};

// Sécurité
cfg.security = { dmPolicy: 'pairing' };

// Workspace partagé
cfg.sharedWorkspace = '/root/.openclaw/workspace-shared';

// gateway.bind — s'assurer qu'il est bien présent (au cas où openclaw.sh ne l'a pas injecté)
if (!cfg.gateway) cfg.gateway = {};
if (!cfg.gateway.bind) cfg.gateway.bind = 'lan';

fs.writeFileSync('$OPENCLAW_JSON', JSON.stringify(cfg, null, 2));
console.log('✅ openclaw.json fusionné avec succès');
"

# ── 4. Initialiser les fichiers partagés ──────────────────────────────────────
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

# ── 5. Vérification finale ─────────────────────────────────────────────────────
echo ""
echo "✅ Installation terminée !"
echo ""
echo "Structure créée :"
find "$OPENCLAW_DIR" -maxdepth 2 -type d | sort
echo ""
echo "Agents configurés dans openclaw.json :"
node -e "
  const cfg = JSON.parse(require('fs').readFileSync('$OPENCLAW_JSON', 'utf8'));
  (cfg.agents?.list || []).forEach(a => console.log('  ✅', a.id, '—', a.model));
"
echo ""
echo "📌 Channels Slack à créer dans ton workspace :"
echo "   #general            → orchestrator"
echo "   #strategist-veille  → strategist"
echo "   #ux-research        → ux-researcher"
echo "   #product-backlog    → product"
echo "   #dev-backend        → dev-python"
echo "   #dev-mobile         → dev-flutter"
echo "   #marketing          → marketer"
echo "   #sysadmin-ops       → sysadmin"
echo ""
echo "📌 Redémarre OpenClaw pour charger la config :"
echo "   sudo systemctl restart openclaw-gateway"
echo ""
echo "📌 Dashboard : http://$(hostname -I | awk '{print $1}'):18789"