#!/usr/bin/env bash
# Render a sanitized manifest with REAL values, then apply — without ever putting
# real values into the git-tracked yaml. (Borrowed idea: CDK injects account/region
# from the environment instead of hardcoding them.)
#
#   bash render-and-apply.sh 04-configmap.yaml            # render + show + apply (asks)
#   bash render-and-apply.sh 04-configmap.yaml --dry-run  # render + print only, no apply
#
# Real values come from values.local.env (gitignored). Placeholders <KEY> in the yaml
# are replaced by the matching KEY=value line. Rendered output goes to a temp file that
# is applied and deleted — the source yaml keeps its placeholders.

set -euo pipefail

FILE="${1:-}"
DRY="${2:-}"
VALUES="values.local.env"

[ -z "$FILE" ] && { echo "usage: bash render-and-apply.sh <manifest.yaml> [--dry-run]"; exit 1; }
[ -f "$FILE" ] || { echo "❌ no such file: $FILE"; exit 1; }
[ -f "$VALUES" ] || { echo "❌ $VALUES not found. Copy values.example.env -> values.local.env and fill it."; exit 1; }

# build sed script from values.local.env (skip comments/blank)
SED_ARGS=()
while IFS='=' read -r key val; do
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [ -z "$key" ] && continue
  SED_ARGS+=(-e "s|<${key}>|${val}|g")
done < "$VALUES"

TMP="$(mktemp -t rendered-XXXX.yaml)"
trap 'rm -f "$TMP"' EXIT
sed "${SED_ARGS[@]}" "$FILE" > "$TMP"

# safety: refuse to apply if any placeholder still remains (missing key in values)
if grep -qE '<[A-Z_]+>' "$TMP"; then
  echo "❌ Unresolved placeholders remain after render (missing key in $VALUES):"
  grep -nE '<[A-Z_]+>' "$TMP" | sed 's/^/   /'
  exit 1
fi

echo "✅ Rendered $FILE (placeholders replaced, real values NOT written to source)."
if [ "$DRY" = "--dry-run" ]; then
  echo "── rendered (dry-run, not applied) ──"
  grep -nE "account|s3_bucket|host:|PROXY_BASE_URL|certificate-arn" "$TMP" | sed 's/^/   /' || true
  exit 0
fi

echo "── about to: kubectl apply -f <rendered $FILE> ──"
read -r -p "Proceed? [y/N] " ans
[ "$ans" = "y" ] || { echo "aborted."; exit 0; }
kubectl apply -f "$TMP"
