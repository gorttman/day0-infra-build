#!/usr/bin/env bash
# Item 12 - correct two stale/missing pieces of documentation.
#
# 1. variables/cli/hosts.ini claims QNAP SSH is "password-only today" and
#    cites the pre-migration IP 192.168.1.30. Both are wrong: key auth via
#    qnap_ansible_ed25519 works and group_vars/qnap.yml already uses it.
#    That comment caused a wrong finding in the 2026-09-04 audit.
# 2. The rebuild runbook never mentions that infra/unifi-tf-secrets is
#    applied by Ansible, not ArgoCD, so a rebuilder reads it as missing.
set -uo pipefail
D="$HOME/gm-dev/day0-infra-build"
cd "$D" || { echo "repo missing"; exit 2; }
grep -q "password-only" variables/cli/hosts.ini || grep -q "unifi-tf-secrets" docs/rebuild-runbook.md && \
  { grep -q "unifi-tf-secrets" docs/rebuild-runbook.md && ! grep -q "password-only" variables/cli/hosts.ini && { echo "already corrected"; exit 0; }; }
python3 - "$D" <<'PY'
import sys,os,re
d=sys.argv[1]
p=os.path.join(d,"variables/cli/hosts.ini"); s=open(p).read()
s=re.sub(r"Requires\s*\n?#?\s*key-based SSH auth.*?before running qnap-manage\.yml\.",
 "Uses key-based SSH auth via ~/.ssh/qnap_ansible_ed25519, which\n# group_vars/qnap.yml sets as ansible_ssh_private_key_file. Verified\n# working 2026-09-04. Testing with the default key instead gives\n# Permission denied and makes it look like no key auth exists - an\n# earlier version of this comment said exactly that and was wrong.",
 s, flags=re.S)
open(p,'w').write(s)

p=os.path.join(d,"docs/rebuild-runbook.md"); s=open(p).read()
if "unifi-tf-secrets" not in s:
    note=("\n## Secrets applied outside ArgoCD\n\n"
          "`infra/unifi-tf-secrets` is applied by Ansible\n"
          "(`roles/unifi_tf_apply/files/unifi-tf-sealedsecret.yml`), not by the\n"
          "app-of-apps. It carries no ArgoCD tracking annotation, so it reads as\n"
          "unmanaged drift when auditing the cluster against Git. That is\n"
          "expected. Every other SealedSecret in the cluster is ArgoCD-managed.\n")
    s = s.rstrip("\n") + "\n" + note
    open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add variables/cli/hosts.ini docs/rebuild-runbook.md
git diff --cached --quiet && { echo "no changes needed"; exit 0; }
git commit -q -m "Correct stale QNAP SSH comment and document unifi-tf-secrets

hosts.ini claimed QNAP access was password-only and cited the
pre-migration IP. Key auth via qnap_ansible_ed25519 works and
group_vars/qnap.yml already uses it; the stale comment produced a wrong
finding in the 2026-09-04 audit.

Also records that infra/unifi-tf-secrets is Ansible-applied, so it is not
mistaken for unmanaged drift during a rebuild.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
echo "docs corrected and pushed"; exit 0
