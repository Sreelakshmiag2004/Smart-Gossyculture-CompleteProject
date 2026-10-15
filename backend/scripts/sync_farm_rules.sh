#!/usr/bin/env bash
# The backend runs the SAME farm rules as the cart and the experiments: an exact copy of
# bollbot/core (engine) and two bollbot/config files (thresholds). Change them in bollbot/,
# then run this script from anywhere in the repo to copy them here.
#   bash backend/scripts/sync_farm_rules.sh          copy bollbot -> backend
#   bash backend/scripts/sync_farm_rules.sh --check  fail if the copies differ (CI)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"          # backend/
src="$here/../bollbot"
dst="$here/src/gossy/farmrules"
files=(core/__init__.py core/config.py core/models.py core/rules.py core/etl.py core/messages.py core/engine.py
       config/thresholds.yaml config/etl.yaml)
status=0
for f in "${files[@]}"; do
  if [[ "${1:-}" == "--check" ]]; then
    if ! diff -u "$src/$f" "$dst/$f"; then
      echo "::error::backend/src/gossy/farmrules/$f differs from bollbot/$f - run: bash backend/scripts/sync_farm_rules.sh"
      status=1
    fi
  else
    mkdir -p "$(dirname "$dst/$f")"
    cp "$src/$f" "$dst/$f"
  fi
done
[[ "${1:-}" == "--check" && $status -eq 0 ]] && echo "farm rules: backend copy matches bollbot/ (${#files[@]} files)"
exit $status
