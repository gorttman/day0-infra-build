#!/usr/bin/env bash
# Item 15 - remove the orphaned n8n namespace.
#
# Item 14a removed n8n from the app-of-apps expecting prune to clean up.
# It didn't: n8n-app.yml carries no resources-finalizer.argocd.argoproj.io,
# so deleting the Application detached the resources instead of deleting
# them. No app in day2-services has that finalizer, so this is how every
# app removal in this repo behaves - see item 16.
#
# The resources are now orphaned: running, unmanaged, in no Application.
# That is worse than either keeping or removing them, so finish the job.
#
# Deletes the namespace, which cascades the service, deployment, ingress,
# n8n-tls cert, n8n-secrets and the 2Gi Longhorn PVC. Zero workflows means
# nothing in that volume matters. The postgres n8n database is untouched.
#
# Deployment is already at 0 replicas, so nothing stops serving.
set -uo pipefail

STAMP="$(date +%F-%H%M)"
MANIFEST="$(dirname "${BASH_SOURCE[0]}")/state/15-n8n-removed-$STAMP.manifest"

if ! sudo kubectl get ns n8n >/dev/null 2>&1; then
    echo "n8n namespace already gone"; exit 0
fi

# Must not race ArgoCD: if the Application still exists, selfHeal would
# recreate whatever we delete.
if sudo kubectl get app n8n -n argocd >/dev/null 2>&1; then
    echo "n8n Application still exists in ArgoCD - run item 14 first"; exit 2
fi

# Confirm it is genuinely commented out in Git, so a later sync cannot
# bring it back underneath us.
if ! grep -qE '^\s*#\s*- n8n/n8n-app\.yml' "$HOME/gm-dev/day2-services/apps/kustomization.yml"; then
    echo "n8n is not commented out in day2-services - refusing"; exit 2
fi

# Nothing may be running. Zero workflows is the premise of this whole item.
replicas="$(sudo kubectl get deploy n8n -n n8n -o jsonpath='{.status.replicas}' 2>/dev/null)"
if [ -n "${replicas:-}" ] && [ "$replicas" != "0" ]; then
    echo "n8n deployment has $replicas replicas running - refusing"; exit 2
fi

{
    echo "# n8n namespace removal $STAMP"
    sudo kubectl get all,pvc,ingress,secret -n n8n 2>/dev/null
} > "$MANIFEST"
detail "recorded contents to $MANIFEST"

PV="$(sudo kubectl get pvc n8n-data -n n8n -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
detail "backing PV: ${PV:-none}"

sudo kubectl delete ns n8n --wait=true --timeout=180s >>"$DETAIL" 2>&1 \
    || { echo "namespace delete failed or timed out - see $DETAIL"; exit 1; }

if sudo kubectl get ns n8n >/dev/null 2>&1; then
    echo "namespace still present after delete"; exit 1
fi

pvstate="gone"
if [ -n "${PV:-}" ]; then
    pvstate="$(sudo kubectl get pv "$PV" -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)"
fi
echo "n8n namespace removed; backing PV ${PV:-none} now ${pvstate:-gone}; manifest $(basename "$MANIFEST")"
exit 0
