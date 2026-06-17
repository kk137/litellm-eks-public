#!/usr/bin/env bash
# Pre-apply guard: scan a manifest (or all yaml) for unreplaced placeholders.
# Usage:
#   bash check-placeholders.sh 05-deployment.yaml   # check one file
#   bash check-placeholders.sh                       # check all *.yaml in repo
# Exit 1 if any placeholder found — wire this before `kubectl apply`.
#
# Why: this repo is a sanitized public copy. Files like 01/05/07 carry placeholders
# (<YOUR_ACCOUNT_ID>, <YOUR_DOMAIN>, <REGION>, ...). Applying them to the live cluster
# overwrites real config and broke the UI once (placeholder PROXY_BASE_URL => invalid
# login URL => client-side exception). Always check first; prefer `kubectl patch`/`set env`
# for single-field changes instead of applying the whole file.

set -u
PATTERN='<YOUR_[A-Za-z_]*>|<REGION>|<[A-Z_]+_ID>|<YOUR_ALLOWED_CIDRS>'

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  # no arg → all tracked-ish yaml in repo root
  mapfile -t targets < <(ls -1 *.yaml *.yml 2>/dev/null)
fi

found=0
for f in "${targets[@]}"; do
  [ -f "$f" ] || { echo "skip (not a file): $f"; continue; }
  hits=$(grep -nE "$PATTERN" "$f" 2>/dev/null)
  if [ -n "$hits" ]; then
    found=1
    echo "❌ $f — PLACEHOLDERS FOUND, do NOT kubectl apply:"
    echo "$hits" | sed 's/^/     /'
  else
    echo "✅ $f — clean"
  fi
done

if [ "$found" -eq 1 ]; then
  echo ""
  echo "⛔ Placeholders present. Replace them (or use kubectl patch/set env) before applying."
  exit 1
fi
echo ""
echo "✓ No placeholders. Safe to apply."
