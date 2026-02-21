#!/usr/bin/env bash
# Verifies that each Installs/*.sh script follows the required template structure.
# Skips _Template.sh (reference) and _Empty.sh (intentionally minimal).
# Exit code 0 = all checks passed, 1 = one or more failures.

set -euo pipefail

INSTALLS_DIR="./Installs"

# Files that are intentionally exempt from structure requirements
EXEMPT=("_Template.sh" "_Empty.sh")

# Patterns that MUST appear in every install script.
# Each entry is: "pattern|description"
declare -a REQUIRED=(
  "FUNCTIONS_FILE_PATH|standalone execution guard (if [[ ! -v FUNCTIONS_FILE_PATH ]])"
  "verb_ip6|IPv6 + verbose mode initialisation"
  "catch_errors|error handler setup"
  "setting_up_container|container OS setup"
  "network_check|network connectivity check"
  "update_os|OS package update"
  "motd_ssh|MOTD and SSH configuration"
  "customize|container customisation (auto-login / password)"
)

errors=0
checked=0

for script in "$INSTALLS_DIR"/*.sh; do
  base=$(basename "$script")

  # Skip exempt files
  skip=0
  for excl in "${EXEMPT[@]}"; do
    [[ "$base" == "$excl" ]] && skip=1 && break
  done
  [[ "$skip" == 1 ]] && echo "SKIP: $base (exempt)" && continue

  checked=$((checked + 1))
  file_errors=0

  for entry in "${REQUIRED[@]}"; do
    pattern="${entry%%|*}"
    description="${entry##*|}"
    if ! grep -q "$pattern" "$script"; then
      echo "FAIL: $base — missing '$pattern' ($description)"
      file_errors=$((file_errors + 1))
      errors=$((errors + 1))
    fi
  done

  if [ "$file_errors" -eq 0 ]; then
    echo "OK  : $base"
  fi
done

echo ""
echo "Checked $checked install script(s)."
if [ "$errors" -gt 0 ]; then
  echo "Found $errors structure error(s). Refer to Installs/_Template.sh."
  exit 1
fi
echo "All structure checks passed."
