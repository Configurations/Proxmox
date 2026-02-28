#!/bin/bash
# install-agents.sh
# Configure tous les agents OpenClaw pour le projet coaching sportif
# À exécuter DANS le container LXC après `openclaw onboard`

set -e

OPENCLAW_DIR="$HOME/.openclaw"
PROMPTS_DIR="$OPENCLAW_DIR/prompts"
SHARED_DIR="$OPENCLAW_DIR/workspace-shared"

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

# ── 2. Copier les system prompts ───────────────────────────────────────────────
echo "📝 Copie des system prompts..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_SRC="$SCRIPT_DIR/prompts"

for agent in orchestrator strategist ux-researcher product dev-python dev-flutter marketer sysadmin; do
  if [ -f "$PROMPTS_SRC/$agent.md" ]; then
    cp "$PROMPTS_SRC/$agent.md" "$PROMPTS_DIR/$agent.md"
    echo "  ✅ $agent.md"
  else
    echo "  ⚠️  $agent.md introuvable dans $PROMPTS_SRC"
  fi
done

# ── 3. Copier la config JSON ───────────────────────────────────────────────────
echo "⚙️  Copie de openclaw.json..."
if [ -f "$SCRIPT_DIR/openclaw.json" ]; then
  # Backup de l'existant si présent
  if [ -f "$OPENCLAW_DIR/openclaw.json" ]; then
    cp "$OPENCLAW_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json.bak"
    echo "  📦 Backup créé : openclaw.json.bak"
  fi
  cp "$SCRIPT_DIR/openclaw.json" "$OPENCLAW_DIR/openclaw.json"
  echo "  ✅ openclaw.json installé"
else
  echo "  ⚠️  openclaw.json introuvable dans $SCRIPT_DIR"
fi

# ── 4. Rappel channels Slack à créer ──────────────────────────────────────────
echo ""
echo "📣 Channels Slack à créer dans ton workspace :"
echo "   #general            → orchestrator"
echo "   #strategist-veille  → strategist"
echo "   #ux-research        → ux-researcher"
echo "   #product-backlog    → product"
echo "   #dev-backend        → dev-python"
echo "   #dev-mobile         → dev-flutter"
echo "   #marketing          → marketer"
echo "   #sysadmin-ops       → sysadmin"
echo ""
echo "   Configure SLACK_BOT_TOKEN et SLACK_APP_TOKEN dans : openclaw onboard"
echo ""

# ── 5. Initialiser les fichiers partagés ──────────────────────────────────────
echo "📋 Initialisation du workspace partagé..."

# changelog.md
if [ ! -f "$SHARED_DIR/changelog.md" ]; then
cat > "$SHARED_DIR/changelog.md" << 'EOF'
# Changelog — Workspace Partagé

Format : [YYYY-MM-DD HH:MM] agent — action effectuée

---
EOF
  echo "  ✅ changelog.md initialisé"
fi

# decisions.md
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
tree "$OPENCLAW_DIR" -L 2 2>/dev/null || find "$OPENCLAW_DIR" -maxdepth 2 -type d | sort
echo ""
echo "📌 Prochaine étape :"
echo "   Redémarre OpenClaw pour charger la nouvelle config :"
echo "   sudo systemctl restart openclaw-gateway"
echo ""
echo "📌 Teste l'orchestrator via Telegram avec :"
echo "   /start  →  devrait activer l'agent orchestrator"
