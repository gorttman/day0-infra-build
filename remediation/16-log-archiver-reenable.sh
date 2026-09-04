#!/usr/bin/env bash
# Item 16 - re-enable log-archiver, bounded so it cannot hang again.
#
# Suspended 2026-07-04 because runs "were failing and hanging for 20h+".
# Every prerequisite was re-verified 2026-09-04 and is correct now:
#   log-archiver-secret exists, NAS_IP_ADDRESS=192.168.20.30 (the current
#   Trusted-VLAN address), NFS_EXPORT_PATH=/syslog-archive, and
#   /share/CACHEDEV1_DATA/syslog-archive exists and is exported.
#
# The hang itself was unbounded: no activeDeadlineSeconds, so a stuck NFS
# mount blocked until someone noticed. That is fixed here regardless of
# root cause - a bad run now dies in 30 minutes and reports failure.
#
# Proves it with a real run rather than assuming. If the test fails the
# CronJob is put straight back to suspended, so this cannot leave a
# broken job firing nightly.
set -uo pipefail
F="$HOME/gm-dev/day1-foundation/apps/log-archiver/log-archiver-cronjob.yml"
cd "$HOME/gm-dev/day1-foundation" || { echo "repo missing"; exit 2; }
[ -n "$(git status --porcelain)" ] && { echo "tree dirty"; exit 2; }
if grep -qE "^\s*suspend: false" "$F"; then echo "already re-enabled"; exit 0; fi

python3 - "$F" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old=("  # Disabled 2026-07-04 (runs were failing and hanging for 20h+); re-enable\n"
     "  # by setting suspend: false once the job itself is fixed\n"
     "  suspend: true\n")
new=("  # Re-enabled 2026-09-04. Disabled 2026-07-04 for failing and hanging\n"
     "  # 20h+. All prerequisites re-verified: the secret exists, NAS_IP is\n"
     "  # the current 192.168.20.30, and /syslog-archive exists and is\n"
     "  # exported. The unbounded hang is fixed by activeDeadlineSeconds\n"
     "  # below, so a stuck mount now fails in 30 minutes instead of\n"
     "  # blocking until noticed.\n"
     "  suspend: false\n")
assert old in s
s=s.replace(old,new,1)
a="    spec:\n      template:\n"
assert a in s
s=s.replace(a,"    spec:\n      activeDeadlineSeconds: 1800\n      backoffLimit: 2\n      template:\n",1)
open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add "$F"
git commit -q -m "Re-enable log-archiver with a hard runtime deadline

Suspended since 2026-07-04 for hanging 20h+. Prerequisites re-verified as
correct: secret present, NAS_IP is the current 192.168.20.30, and
/syslog-archive exists and is exported on the QNAP.

The unbounded hang was the real defect - no activeDeadlineSeconds meant a
stuck NFS mount blocked indefinitely. Now capped at 30 minutes with
backoffLimit 2, so a bad run fails visibly instead of silently occupying
the schedule.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }

for i in $(seq 1 30); do
  [ "$(sudo kubectl get cronjob log-archiver -n logging -o jsonpath='{.spec.suspend}' 2>/dev/null)" = "false" ] && break
  sleep 10
done
[ "$(sudo kubectl get cronjob log-archiver -n logging -o jsonpath='{.spec.suspend}' 2>/dev/null)" = "false" ] \
  || { echo "pushed but ArgoCD has not applied suspend: false"; exit 1; }

# concurrencyPolicy is Forbid, which does not block hand-created Jobs -
# confirm nothing is running before adding one.
if [ -n "$(sudo kubectl get jobs -n logging -o json 2>/dev/null | python3 -c "
import json,sys
print(''.join(j['metadata']['name'] for j in json.load(sys.stdin)['items']
      if j['metadata']['name'].startswith('log-archiver') and not j['status'].get('completionTime')
      and not j['status'].get('failed')))")" ]; then
    echo "a log-archiver Job is already active - not starting a test"; exit 2
fi

T="log-archiver-remediation-test"
sudo kubectl delete job "$T" -n logging --ignore-not-found >>"$DETAIL" 2>&1
sudo kubectl create job "$T" -n logging --from=cronjob/log-archiver >>"$DETAIL" 2>&1 \
  || { echo "could not create test job"; exit 1; }
sudo kubectl wait --for=condition=complete --timeout=900s job/"$T" -n logging >>"$DETAIL" 2>&1
rc=$?
sudo kubectl logs job/"$T" -n logging --tail=25 >>"$DETAIL" 2>&1
if [ $rc -eq 0 ]; then
    sudo kubectl delete job "$T" -n logging --ignore-not-found >>"$DETAIL" 2>&1
    echo "log-archiver re-enabled and a real run completed successfully"; exit 0
fi
# Failed - do not leave a broken job enabled.
python3 - "$F" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace("  suspend: false\n","  suspend: true\n",1))
PY
git add "$F"
git commit -q -m "Re-suspend log-archiver: test run still fails

Re-enabled with a deadline, but a real run did not complete. The
activeDeadlineSeconds cap stays so it can never hang 20h again, but the
job itself still needs diagnosis before it runs nightly.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1
git push -q origin main >>"$DETAIL" 2>&1
echo "test run failed - deadline added, job left suspended, needs diagnosis (see $DETAIL)"
exit 2
