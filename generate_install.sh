#!/usr/bin/env bash
# Equivalent bash de generate_install.ps1
# Scanne le dossier Installs/ et génère applications.txt

INSTALLS_DIR="${1:-./Installs}"
OUTPUT_FILE="${2:-./applications.txt}"

if [ ! -d "$INSTALLS_DIR" ]; then
  echo "Erreur : Le répertoire '$INSTALLS_DIR' n'existe pas." >&2
  exit 1
fi

result=$(find "$INSTALLS_DIR" -maxdepth 1 -name "*.sh" -exec basename {} .sh \; | sort | paste -sd ';')

if [ -z "$result" ]; then
  echo "Erreur : Aucun fichier .sh trouvé dans '$INSTALLS_DIR'." >&2
  exit 1
fi

echo "$result" > "$OUTPUT_FILE"
echo "Liste des applications enregistrée dans : $OUTPUT_FILE"
