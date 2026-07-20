#!/bin/bash
# seal_secret.sh - Helper to generate a SealedSecret YAML for GitOps
# Usage: seal_secret.sh <app-name> <key1=val1> [<key2=val2> ...]

set -e

if [ $# -lt 2 ]; then
  echo "Usage: $0 <app-name> <key=value> [<key=value> ...]"
  exit 1
fi

APP_NAME=$1
shift

# Build kubectl command with --from-literal args
SECRET_ARGS=()
for kv in "$@"; do
  SECRET_ARGS+=(--from-literal="$kv")
done

# Create a temporary plain Secret YAML
PLAIN_TMP="/tmp/${APP_NAME}-secret.yaml"
trap 'shred -u "$PLAIN_TMP" 2>/dev/null || rm -f "$PLAIN_TMP"' EXIT

kubectl create secret generic "$APP_NAME-secret" \
  "${SECRET_ARGS[@]}" \
  --dry-run=client -o yaml > "$PLAIN_TMP"

# Seal it with cluster's public key. Controller name is the live k8s
# Service name (kubectl get svc -n kube-system), not the app/product
# name - confirmed 2026-07-19 this was "sealed-secret" (singular) here,
# which doesn't match the real "sealed-secrets-controller" Service and
# would fail to fetch the controller's cert.
kubeseal \
  --controller-namespace kube-system \
  --controller-name sealed-secrets-controller \
  --format yaml \
  < "$PLAIN_TMP" \
  > "${APP_NAME}-sealed-secret.yaml"

echo "✅ Created ${APP_NAME}-sealed-secret.yaml"
echo "→ Commit this file to the appropriate Git repo (e.g. apps/${APP_NAME}/secrets/)"
