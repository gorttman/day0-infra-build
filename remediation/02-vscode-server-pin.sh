#!/usr/bin/env bash
# Item 2 - pin vscode-server back to k8smaster.
#
# Both Deployments mount hostPath /home/gorttman (type: Directory). The
# hard k8smaster nodeSelector was removed 2026-08-17 during a bulk
# rebalance onto pinode-01, which treated this app like any other - but
# its hostPath content is k8smaster-specific. pinode-01's /home/gorttman
# is a bare skeleton with no gm-dev, so the IDE has been running against
# an empty home. Verified live 2026-09-04.
#
# The workload-affinity patch is preferredDuringScheduling (soft), so a
# nodeSelector takes precedence without conflicting.
#
# Moves both pods back to k8smaster - the IDE session drops and reconnects.
set -uo pipefail
D="$HOME/gm-dev/day2-services/apps/vscode-server"
cd "$HOME/gm-dev/day2-services" || { echo "repo missing"; exit 2; }
grep -qE "^\s+kubernetes.io/hostname: k8smaster" "$D/vscode-gorttman-deployment.yml" 2>/dev/null && { echo "already pinned"; exit 0; }
[ -n "$(git status --porcelain)" ] && { echo "tree dirty"; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "not on main"; exit 2; }
python3 - "$D" <<'PY'
import sys,os,re
d=sys.argv[1]
note=("      # Re-pinned 2026-09-04. Both Deployments mount hostPath\n"
      "      # /home/gorttman, whose content only exists on k8smaster -\n"
      "      # pinode-01 has a bare skeleton home with no gm-dev, so the\n"
      "      # 2026-08-17 unpinning left the IDE running against an empty\n"
      "      # directory. Soft workload-affinity below still applies among\n"
      "      # nodes this selector allows.\n"
      "      nodeSelector:\n"
      "        kubernetes.io/hostname: k8smaster\n")
for f in ("vscode-gorttman-deployment.yml","vscode-gorttman-auth-deployment.yml"):
    p=os.path.join(d,f); s=open(p).read()
    assert "\n    spec:\n" in s, f
    # Match the YAML key, not the word - the file carries a comment
    # explaining the 2026-08-17 removal that mentions nodeSelector.
    assert not re.search(r"^\s+nodeSelector:", s, re.M), f+" already has one"
    s=s.replace("\n    spec:\n","\n    spec:\n"+note,1)
    open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add apps/vscode-server/
git commit -q -m "Pin vscode-server back to k8smaster

Both Deployments mount hostPath /home/gorttman with type: Directory. That
path exists on pinode-01 but holds only a skeleton home - no gm-dev, no
repos - so since the 2026-08-17 rebalance the IDE has been serving an
empty directory. Verified live before this change.

The bulk rebalance applied the same pinode-01 tmpfs reasoning as every
other app, which does not hold for a workload whose hostPath content is
node-specific.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
for i in $(seq 1 30); do
  n=$(sudo kubectl get pods -n vscode-server -o jsonpath='{range .items[*]}{.spec.nodeName} {end}' 2>/dev/null)
  case "$n" in *pinode-01*) sleep 10;; *k8smaster*) echo "vscode-server now on k8smaster"; exit 0;; *) sleep 10;; esac
done
echo "pushed but pods not yet all on k8smaster"; exit 1
