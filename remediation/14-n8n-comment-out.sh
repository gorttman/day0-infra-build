#!/usr/bin/env bash
# Item 14a - stop deploying n8n.
#
# n8n has zero workflows and is not in use. It already runs at replicas: 0,
# so nothing is serving traffic and this costs no availability.
#
# Commenting it out of the app-of-apps makes ArgoCD delete the Application,
# and prune then removes the n8n namespace and everything in it: service,
# deployment, ingress, the n8n-tls cert, n8n-secrets, and the 2Gi Longhorn
# PVC. With zero workflows there is nothing in that volume worth keeping,
# and every manifest stays in Git - uncommenting one line restores it.
#
# Deliberately NOT touched here:
#   - the postgres n8n database (13 MB) and its nightly dump. Postgres is a
#     separate app, the database survives on its own, and dropping it is the
#     one irreversible part of this. Keeping it costs 13 MB.
#   - DNS. dns-conf/coredns/fragments/i3sec-hosts.server and
#     dns-conf/pihole/pihole-custom-dns-cm.yml both still resolve
#     n8n.i3sec.com.au to the Traefik VIP, which will start returning 404.
#     Removing those reloads LAN-wide DNS, so it is item 14b, out of hours.
#
# n8n serves nothing today, so this has no network impact.
set -uo pipefail

REPO="$HOME/gm-dev/day2-services"
KUSTOMIZATION="$REPO/apps/kustomization.yml"
LINE="  - n8n/n8n-app.yml"

cd "$REPO" || { echo "repo missing: $REPO"; exit 2; }

if grep -qE '^\s*#\s*- n8n/n8n-app\.yml' "$KUSTOMIZATION"; then
    echo "n8n already commented out"; exit 0
fi
grep -qxF "$LINE" "$KUSTOMIZATION" || { echo "expected line not found in kustomization"; exit 2; }

if [ -n "$(git status --porcelain)" ]; then
    echo "day2-services working tree is dirty - not committing"; exit 2
fi
[ "$(git branch --show-current)" = "main" ] || { echo "not on main"; exit 2; }

python3 - "$KUSTOMIZATION" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  - n8n/n8n-app.yml\n"
new = ("  # Commented out 2026-09-04: n8n has zero workflows and is not in\n"
       "  # use. Manifests are kept in apps/n8n/ - uncomment this line to\n"
       "  # bring it back. The postgres n8n database is deliberately left\n"
       "  # in place and still backed up nightly.\n"
       "  # - n8n/n8n-app.yml\n")
assert old in s, "anchor line missing"
open(p, "w").write(s.replace(old, new, 1))
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
detail "commented n8n out of apps/kustomization.yml"

git add apps/kustomization.yml
git commit -q -m "Stop deploying n8n - unused, zero workflows

Runs at replicas: 0 already, so nothing is serving. Removing it from the
app-of-apps lets prune clean up the namespace, ingress, cert and the 2Gi
Longhorn PVC, none of which hold anything with zero workflows.

Manifests stay in apps/n8n/ - uncommenting one line restores it. The
postgres n8n database is left alone and still dumped nightly, since that
is the only irreversible part and it costs 13 MB.

DNS entries for n8n.i3sec.com.au are still in place; removing those
reloads LAN-wide DNS and is handled separately.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 \
    || { echo "commit failed - see $DETAIL"; exit 1; }

git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed - see $DETAIL"; exit 1; }

# Let ArgoCD notice and prune. Poll rather than sleeping blindly.
for i in $(seq 1 30); do
    sudo kubectl get app n8n -n argocd >/dev/null 2>&1 || break
    sleep 10
done

if sudo kubectl get app n8n -n argocd >/dev/null 2>&1; then
    echo "pushed, but ArgoCD still shows the n8n Application after 5m"; exit 1
fi
ns="$(sudo kubectl get ns n8n -o jsonpath='{.status.phase}' 2>/dev/null || echo Gone)"
echo "n8n commented out and pushed; Application removed, namespace=${ns:-Gone}"
exit 0
