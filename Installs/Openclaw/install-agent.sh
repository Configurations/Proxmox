#!/bin/bash
# install-agent.sh
# Installe un agent OpenClaw individuel avec ses fichiers d'identité
# bash -c "$(wget -qLO - https://raw.githubusercontent.com/Configurations/Proxmox/refs/heads/main/Installs/Openclaw/install-agent.sh)"

set -e

BASE_URL="https://github.com/Configurations/Proxmox/raw/main/Installs/Openclaw"
AGENTS_LIST_URL="$BASE_URL/agents.txt"
OPENCLAW_DIR="/root/.openclaw"

echo "🦞 OpenClaw — Installation d'un agent"
echo ""

# ── 1. Récupérer la liste des agents disponibles ─────────────────────────────
echo "📋 Récupération de la liste des agents..."
AGENTS_RAW=$(wget -qO- "$AGENTS_LIST_URL" 2>/dev/null)

if [ -z "$AGENTS_RAW" ]; then
  echo "❌ Impossible de récupérer la liste des agents depuis :"
  echo "   $AGENTS_LIST_URL"
  exit 1
fi

# Transformer "Orchestrator;dev-flutter;..." en tableau
IFS=';' read -ra AGENTS <<< "$AGENTS_RAW"

echo ""
echo "Agents disponibles :"
echo ""
for i in "${!AGENTS[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${AGENTS[$i]}"
done
echo ""

# ── 2. Demander le choix ──────────────────────────────────────────────────────
while true; do
  read -rp "Choisis un agent (1-${#AGENTS[@]}) : " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#AGENTS[@]}" ]; then
    AGENT_NAME="${AGENTS[$((CHOICE-1))]}"
    break
  fi
  echo "  ⚠️  Choix invalide — entre un nombre entre 1 et ${#AGENTS[@]}"
done

# Nom en minuscules pour les chemins système
AGENT_ID=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')
WORKSPACE_DIR="$OPENCLAW_DIR/workspace-$AGENT_ID"

echo ""
echo "  → Agent sélectionné : $AGENT_NAME (id: $AGENT_ID)"
echo ""

# ── 3. Lancer le wizard openclaw agents add ───────────────────────────────────
echo "🔧 Lancement du wizard OpenClaw..."
echo "   (Le wizard va te demander la clé API et les tokens Slack)"
echo ""
openclaw agents add "$AGENT_ID"

# ── 4. Vérifier que le workspace existe ──────────────────────────────────────
echo ""
if [ -d "$WORKSPACE_DIR" ]; then
  echo "✅ Workspace détecté : $WORKSPACE_DIR"
else
  echo "⚠️  Workspace non trouvé à l'emplacement attendu : $WORKSPACE_DIR"
  echo "   Création du répertoire..."
  mkdir -p "$WORKSPACE_DIR"
fi

# ── 5. Télécharger IDENTITY.md et SOUL.md ────────────────────────────────────
echo ""
echo "📝 Déploiement des fichiers d'identité..."

IDENTITY_URL="$BASE_URL/Agents/$AGENT_NAME/IDENTITY.md"
SOUL_URL="$BASE_URL/Agents/$AGENT_NAME/SOUL.md"

if wget -qO "$WORKSPACE_DIR/IDENTITY.md" "$IDENTITY_URL" 2>/dev/null; then
  echo "  ✅ IDENTITY.md → $WORKSPACE_DIR/IDENTITY.md"
else
  echo "  ⚠️  IDENTITY.md introuvable sur le repo ($IDENTITY_URL)"
fi

if wget -qO "$WORKSPACE_DIR/SOUL.md" "$SOUL_URL" 2>/dev/null; then
  echo "  ✅ SOUL.md → $WORKSPACE_DIR/SOUL.md"
else
  echo "  ⚠️  SOUL.md introuvable sur le repo ($SOUL_URL)"
fi

# ── 6. Résumé ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Agent '$AGENT_NAME' installé !"
echo ""
echo "  Workspace   : $WORKSPACE_DIR"
echo "  Fichiers    : IDENTITY.md, SOUL.md"
echo ""
echo "  Vérifie le statut : openclaw agents list"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
