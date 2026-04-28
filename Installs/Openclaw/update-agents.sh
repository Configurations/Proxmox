#!/bin/bash
# update-agents.sh
# Met à jour les fichiers d'identité de tous les agents OpenClaw installés
# bash -c "$(wget -qLO - https://raw.githubusercontent.com/Configurations/Proxmox/refs/heads/main/Installs/Openclaw/update-agents.sh)"

set -e

BASE_URL="https://github.com/Configurations/Proxmox/raw/main/Installs/Openclaw"
AGENTS_LIST_URL="$BASE_URL/agents.txt"
OPENCLAW_DIR="/root/.openclaw"

echo "🦞 OpenClaw — Mise à jour des agents"
echo ""

# ── 1. Récupérer la liste des agents depuis le repo ──────────────────────────
echo "📋 Récupération de la liste des agents..."
AGENTS_RAW=$(wget -qO- "$AGENTS_LIST_URL" 2>/dev/null)

if [ -z "$AGENTS_RAW" ]; then
  echo "❌ Impossible de récupérer la liste des agents depuis :"
  echo "   $AGENTS_LIST_URL"
  exit 1
fi

IFS=';' read -ra AGENTS <<< "$AGENTS_RAW"
echo "   ${#AGENTS[@]} agents trouvés dans le repo."
echo ""

# ── 2. Récupérer les agents installés localement ─────────────────────────────
echo "🔍 Détection des agents installés..."
INSTALLED=$(openclaw agents list 2>/dev/null || true)
UPDATED=0
SKIPPED=0

echo ""

# ── 3. Pour chaque agent, vérifier et mettre à jour ─────────────────────────
for AGENT_NAME in "${AGENTS[@]}"; do
  AGENT_ID=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')
  WORKSPACE_DIR="$OPENCLAW_DIR/workspace-$AGENT_ID"

  # Vérifier que l'agent existe localement
  if ! echo "$INSTALLED" | grep -qi "$AGENT_ID"; then
    echo "  ⏭️  $AGENT_NAME — non installé, ignoré"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Vérifier que le workspace existe
  if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "  ⚠️  $AGENT_NAME — workspace introuvable ($WORKSPACE_DIR), ignoré"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "  🔄 $AGENT_NAME — mise à jour..."

  # Télécharger IDENTITY.md
  IDENTITY_URL="$BASE_URL/Agents/$AGENT_NAME/IDENTITY.md"
  if wget -qO "$WORKSPACE_DIR/IDENTITY.md" "$IDENTITY_URL" 2>/dev/null; then
    echo "     ✅ IDENTITY.md"
  else
    echo "     ⚠️  IDENTITY.md introuvable sur le repo"
  fi

  # Télécharger SOUL.md
  SOUL_URL="$BASE_URL/Agents/$AGENT_NAME/SOUL.md"
  if wget -qO "$WORKSPACE_DIR/SOUL.md" "$SOUL_URL" 2>/dev/null; then
    echo "     ✅ SOUL.md"
  else
    echo "     ⚠️  SOUL.md introuvable sur le repo"
  fi

  # Fichiers optionnels : AGENTS.md et HEARTBEAT.md
  for OPT_FILE in "AGENTS.md" "HEARTBEAT.md"; do
    OPT_URL="$BASE_URL/Agents/$AGENT_NAME/$OPT_FILE"
    if wget -qO "$WORKSPACE_DIR/$OPT_FILE" "$OPT_URL" 2>/dev/null && [ -s "$WORKSPACE_DIR/$OPT_FILE" ]; then
      echo "     ✅ $OPT_FILE"
    else
      rm -f "$WORKSPACE_DIR/$OPT_FILE"
    fi
  done

  UPDATED=$((UPDATED + 1))
done

# ── 4. Résumé ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📊 Résumé : $UPDATED mis à jour, $SKIPPED ignorés"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 5. Proposer le redémarrage du service ─────────────────────────────────────
if [ "$UPDATED" -gt 0 ]; then
  echo ""
  read -rp "🔁 Redémarrer le service OpenClaw ? (o/N) : " RESTART
  if [[ "$RESTART" =~ ^[oOyY]$ ]]; then
    echo ""
    echo "♻️  Redémarrage du service openclaw-gateway..."
    systemctl restart openclaw-gateway
    echo "✅ Service openclaw-gateway redémarré."
    systemctl status openclaw-gateway --no-pager
  else
    echo ""
    echo "ℹ️  Redémarrage ignoré. Tu peux redémarrer manuellement avec :"
    echo "   systemctl restart openclaw-gateway"
  fi
fi
