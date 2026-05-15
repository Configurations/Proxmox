#!/bin/bash
###############################################################################
# Script : list-instances.sh
#
# A executer sur l'HOTE PROXMOX (pas dans le container/VM).
#
# Liste les LXC et VM presents sur le noeud Proxmox courant et retourne
# un tableau JSON au format :
#
#   [ {"id":"<id>","name":"<name>"}, ... ]
#
# Usage :
#   ./list-instances.sh             # LXC + VM (defaut)
#   ./list-instances.sh --lxc       # LXC uniquement
#   ./list-instances.sh --vm        # VM uniquement
#   ./list-instances.sh --pretty    # JSON indente
#
# Sortie : stdout uniquement. Code de retour non-zero en cas d'erreur.
###############################################################################

set -eo pipefail

MODE="all"
PRETTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lxc)    MODE="lxc"; shift ;;
    --vm)     MODE="vm"; shift ;;
    --all)    MODE="all"; shift ;;
    --pretty) PRETTY=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Option inconnue : $1" >&2
      exit 1 ;;
  esac
done

# Verifie la presence des outils Proxmox attendus
if [[ "$MODE" != "vm" ]] && ! command -v pct >/dev/null 2>&1; then
  echo "Erreur : 'pct' introuvable. Ce script doit s'executer sur un hote Proxmox." >&2
  exit 1
fi
if [[ "$MODE" != "lxc" ]] && ! command -v qm >/dev/null 2>&1; then
  echo "Erreur : 'qm' introuvable. Ce script doit s'executer sur un hote Proxmox." >&2
  exit 1
fi

# Echappe une chaine pour insertion dans du JSON (antislash et guillemets).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

entries=()

# LXC : colonnes "VMID Status Lock Name" -> $1 et $NF
if [[ "$MODE" == "all" || "$MODE" == "lxc" ]]; then
  while read -r id name; do
    [[ -z "$id" ]] && continue
    entries+=("{\"id\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$name")\"}")
  done < <(pct list | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $NF}')
fi

# VM : colonnes "VMID NAME STATUS ..." -> $1 et $2
if [[ "$MODE" == "all" || "$MODE" == "vm" ]]; then
  while read -r id name; do
    [[ -z "$id" ]] && continue
    entries+=("{\"id\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$name")\"}")
  done < <(qm list | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1, $2}')
fi

count=${#entries[@]}

if [[ $PRETTY -eq 1 ]]; then
  if [[ $count -eq 0 ]]; then
    echo "[]"
  else
    printf '[\n'
    for ((i=0; i<count; i++)); do
      if [[ $i -lt $((count-1)) ]]; then
        printf '  %s,\n' "${entries[$i]}"
      else
        printf '  %s\n' "${entries[$i]}"
      fi
    done
    printf ']\n'
  fi
else
  if [[ $count -eq 0 ]]; then
    echo "[]"
  else
    (IFS=','; echo "[${entries[*]}]")
  fi
fi
