#!/usr/bin/env bash
# Item 1 - re-enable the vpn-healer CronJob.
#
# Live state was suspend: true while Git declared no suspend field at all.
# ArgoCD cannot diff a field the desired manifest never mentions, so the
# app stayed Synced and the drift was invisible. Declaring it explicitly
# is the fix: selfHeal can then see and revert any future suspension.
#
# Restarts nothing. Resumes 15-minute PIA peer checks; a rotation would
# briefly reconnect the VPN inside arr-stack only.
set -uo pipefail
F="$HOME/gm-dev/day2-services/apps/arr-stack/vpn-healer/vpn-healer-cronjob.yml"
cd "$HOME/gm-dev/day2-services" || { echo "repo missing"; exit 2; }
grep -q "^  suspend:" "$F" && { echo "suspend already declared in Git"; exit 0; }
[ -n "$(git status --porcelain)" ] && { echo "tree dirty"; exit 2; }
[ "$(git branch --show-current)" = "main" ] || { echo "not on main"; exit 2; }
python3 - "$F" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='  schedule: "*/15 * * * *"\n'
new=('  schedule: "*/15 * * * *"\n'
     '  # Declared explicitly on purpose. This was suspended live while Git\n'
     '  # said nothing about suspend, and ArgoCD cannot diff a field the\n'
     '  # desired state omits - so the job sat dead and the app stayed\n'
     '  # Synced. With the field present, selfHeal reverts any future\n'
     '  # suspension.\n'
     '  suspend: false\n')
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
git add "$F"
git commit -q -m "Declare vpn-healer suspend: false explicitly

Was suspended live while Git omitted the field entirely, so ArgoCD saw no
diff, the app stayed Synced, and PIA peer self-healing was silently dead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
for i in $(seq 1 24); do
  [ "$(sudo kubectl get cronjob vpn-healer -n arr-stack -o jsonpath='{.spec.suspend}' 2>/dev/null)" = "false" ] && { echo "vpn-healer active (suspend=false live)"; exit 0; }
  sleep 10
done
echo "pushed but live suspend still not false after 4m"; exit 1
