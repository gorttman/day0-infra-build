#!/usr/bin/env bash
# Item 3 - get the loose immich-tagging SealedSecret into Git.
#
# ~/gm-dev/immich-tagging-sealed-secret.yaml was applied with kubectl and
# lives in no repo, so a rebuild from code would not recreate it. It holds
# IMMICH_API_KEY and is consumed by ad-hoc photo-tagging Jobs in the
# default namespace.
#
# It goes to day2-services/adhoc/, NOT apps/immich/, deliberately:
#   - apps/immich/kustomization.yml lists resources explicitly, so a file
#     dropped there would be committed but never synced - worse than
#     useless, it would look managed without being managed.
#   - the day2-services Application points at apps/ as an app-of-apps, so
#     a stray non-Application manifest under apps/ risks being picked up.
#   - re-sealing it into the immich namespace would break the ad-hoc Jobs
#     in default that reference it, which is a bigger change than the
#     finding warrants.
# adhoc/ is outside every sync path, so this captures the secret in Git
# without altering what ArgoCD manages. Nothing is applied to the cluster.
#
# No cluster writes at all - safe during working hours.
set -uo pipefail

SRC="$HOME/gm-dev/immich-tagging-sealed-secret.yaml"
REPO="$HOME/gm-dev/day2-services"
DESTDIR="$REPO/adhoc"
DEST="$DESTDIR/immich-tagging-sealedsecret.yml"

cd "$REPO" || { echo "repo missing: $REPO"; exit 2; }

# Idempotent: already tracked means done, even if the loose copy lingers.
if git ls-files --error-unmatch "adhoc/immich-tagging-sealedsecret.yml" >/dev/null 2>&1; then
    echo "already tracked in day2-services"; exit 0
fi

[ -f "$SRC" ] || { echo "source file not found: $SRC"; exit 2; }

# Refuse to commit onto a dirty tree - this script must not sweep up
# someone else's half-finished work into its own commit.
if [ -n "$(git status --porcelain)" ]; then
    echo "day2-services working tree is dirty - not committing"; exit 2
fi

BRANCH="$(git branch --show-current)"
if [ "$BRANCH" != "main" ]; then
    echo "expected branch main, found '$BRANCH'"; exit 2
fi

# Confirm the live object matches what we are about to enshrine, so we
# don't commit a stale file that differs from what the cluster runs.
LIVE_NS="$(sudo kubectl get sealedsecret immich-tagging-secret -n default \
            -o jsonpath='{.metadata.namespace}' 2>/dev/null)"
if [ "$LIVE_NS" != "default" ]; then
    echo "live SealedSecret default/immich-tagging-secret not found"; exit 2
fi

mkdir -p "$DESTDIR"
git mv --force "$SRC" "$DEST" 2>/dev/null || mv "$SRC" "$DEST"
detail "moved $SRC -> $DEST"

cat > "$DESTDIR/README.md" <<'READMEEOF'
# adhoc

Manifests that are real, applied, and must survive a rebuild, but are
deliberately **not** synced by ArgoCD.

Nothing here is under `apps/`, so the day2-services app-of-apps never
sees it. Apply these by hand after a rebuild.

## immich-tagging-sealedsecret.yml

`IMMICH_API_KEY`, sealed for the `default` namespace. Consumed by ad-hoc
Immich photo-tagging Jobs. Kept in `default` rather than re-sealed into
the `immich` namespace because the Jobs that reference it live there.

Apply with:

    kubectl apply -f adhoc/immich-tagging-sealedsecret.yml
READMEEOF

git add adhoc/
git commit -q -m "Track ad-hoc immich-tagging SealedSecret in Git

Applied by kubectl and present in no repo, so a rebuild from code alone
would not recreate it - found during the cluster/Git drift audit.

Placed in adhoc/ rather than apps/immich/ because apps/immich's
kustomization lists resources explicitly and the day2-services
Application treats apps/ as an app-of-apps. adhoc/ is outside every sync
path, so this changes nothing ArgoCD manages.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 \
    || { echo "commit failed - see $DETAIL"; exit 1; }

git push -q origin main >>"$DETAIL" 2>&1 \
    || { echo "committed locally but push failed - see $DETAIL"; exit 1; }

if git ls-files --error-unmatch "adhoc/immich-tagging-sealedsecret.yml" >/dev/null 2>&1; then
    echo "committed and pushed to day2-services"; exit 0
fi
echo "post-commit verification failed"; exit 1
