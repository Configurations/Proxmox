#!/usr/bin/env bash
# Verifies that applications.txt is in sync with Installs/ and that every
# listed application has a corresponding runs/*.sh script.
# Exit code 0 = all checks passed, 1 = one or more failures.

set -euo pipefail

INSTALLS_DIR="./Installs"
RUNS_DIR="./runs"
APPS_FILE="./applications.txt"

errors=0

# ── 1. Check applications.txt is in sync with Installs/ ───────────────────────

expected=$(find "$INSTALLS_DIR" -maxdepth 1 -name "*.sh" \
  ! -name "_Template.sh" \
  -exec basename {} .sh \; \
  | sort | paste -sd ';')

# Strip CR+LF (handles both Windows CRLF and Unix LF line endings)
current=$(tr -d '\r\n' < "$APPS_FILE" | sed 's/;*$//')

if [ "$expected" != "$current" ]; then
  echo "FAIL: applications.txt is out of sync with Installs/"
  echo "  Expected : $expected"
  echo "  Current  : $current"
  echo "  Fix: run ./generate_install.sh (Linux/Mac) or ./generate_install.ps1 (Windows)"
  errors=$((errors + 1))
else
  echo "OK  : applications.txt matches Installs/"
fi

# ── 2. Check each app (except _Empty) has a runs/*.sh script ──────────────────

IFS=';' read -ra APPS <<< "$current"
for app in "${APPS[@]}"; do
  [[ "$app" == "_Empty" ]] && continue

  runs_script="$RUNS_DIR/${app}.sh"
  if [[ ! -f "$runs_script" ]]; then
    echo "FAIL: Missing runs/${app}.sh for app '${app}'"
    errors=$((errors + 1))
  else
    echo "OK  : runs/${app}.sh exists"
  fi
done

# ── 3. Check each runs/*.sh has a matching Installs/*.sh ──────────────────────

while IFS= read -r -d '' runs_file; do
  base=$(basename "$runs_file" .sh)
  # Exclude generic entry points
  [[ "$base" == "start" ]] && continue

  installs_script="$INSTALLS_DIR/${base}.sh"
  if [[ ! -f "$installs_script" ]]; then
    echo "FAIL: runs/${base}.sh has no matching Installs/${base}.sh"
    errors=$((errors + 1))
  fi
done < <(find "$RUNS_DIR" -maxdepth 1 -name "*.sh" -print0)

# ── Result ─────────────────────────────────────────────────────────────────────

echo ""
if [ "$errors" -gt 0 ]; then
  echo "Found ${errors} error(s). Fix them before merging."
  exit 1
fi
echo "All checks passed."
