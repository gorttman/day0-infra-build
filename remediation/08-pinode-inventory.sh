#!/usr/bin/env bash
# Item 8 - put pinode-01 in the Ansible inventory.
#
# The inventory held only k8smaster (ansible_connection=local) and the
# QNAP, so `hosts: all` never actually meant all: pinode-01 got no
# host-level QNAP mounts and no Ansible management of any kind. Its
# rootfs is built by populate_node_root_lun.yml, which writes a minimal
# fstab (proc + root UUID only), so nothing else supplied them either.
#
# SSH to it works via ~/.ssh/pinode_cluster_ed25519 - verified 2026-09-04.
# An earlier finding claimed pinode-01 SSH was broken; that test used the
# default key, the same mistake made with the QNAP.
#
# Guards first: qnap_client installs three k8smaster-specific cron jobs
# (credentials rsync, postgres-backup staging sync, etcd snapshot sync)
# with no host condition. Adding pinode-01 to `hosts: all` without
# guarding those would install them on a node that has none of the
# source directories, producing nightly errors.
set -uo pipefail
D="$HOME/gm-dev/day0-infra-build"
cd "$D" || { echo "repo missing"; exit 2; }
if grep -q "^pinode-01" variables/cli/hosts.ini 2>/dev/null; then echo "pinode-01 already in inventory"; exit 0; fi
[ -n "$(git status --porcelain roles/qnap_client variables/cli)" ] && { echo "tree dirty in target paths"; exit 2; }

python3 - "$D" <<'PY'
import sys,os,re
d=sys.argv[1]
p=os.path.join(d,"roles/qnap_client/tasks/main.yml"); s=open(p).read()
guard = ("  # k8smaster only: the source directories for this live there and\n"
         "  # nowhere else. Before pinode-01 joined the inventory `hosts: all`\n"
         "  # meant one host, so these needed no condition.\n"
         "  when: inventory_hostname == 'k8smaster'\n")
names = [
 "Ensure off-box credentials backup destination exists on the QNAP",
 "Install daily off-box sync of credentials/ to the QNAP",
 "Ensure postgres-backup's local staging directory exists with correct ownership",
 "Install sync of postgres-backup staging to the QNAP",
 "Install off-box sync of etcd snapshots to the QNAP",
]
for n in names:
    esc = re.escape(n)
    m = re.search(r"(- name: %s\n)" % esc, s)
    assert m, "task not found: " + n
    if "when: inventory_hostname" in s[m.end():m.end()+400]:
        continue
    s = s[:m.end()] + guard + s[m.end():]
open(p,'w').write(s)

p=os.path.join(d,"variables/cli/hosts.ini"); s=open(p).read()
add = ('\n# Added 2026-09-04. Previously absent entirely, which quietly made\n'
       '# `hosts: all` mean "k8smaster and the QNAP" - pinode-01 received no\n'
       '# host-level QNAP mounts and no Ansible management at all. Its rootfs\n'
       '# is written by populate_node_root_lun.yml with a minimal fstab, so\n'
       '# qnap_client is what supplies its /mnt mounts.\n'
       '[workers]\n'
       'pinode-01 ansible_host=192.168.20.11 ansible_user=gorttman '
       'ansible_ssh_private_key_file=~/.ssh/pinode_cluster_ed25519\n')
if "[workers]" not in s:
    s = s.rstrip("\n") + "\n" + add
open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
ansible-playbook day0-infra-build.yml --tags manage_qnap --syntax-check >>"$DETAIL" 2>&1 \
  || { echo "syntax check failed"; exit 1; }
git add roles/qnap_client/tasks/main.yml variables/cli/hosts.ini
git commit -q -m "Add pinode-01 to the Ansible inventory

The inventory held only k8smaster and the QNAP, so 'hosts: all' never
included the worker. pinode-01 therefore had no host-level QNAP mounts
and no Ansible management, and its LUN-written fstab carries only proc
and root.

Guards the three k8smaster-specific cron tasks in qnap_client first
(credentials rsync, postgres staging sync, etcd snapshot sync) - their
source directories exist only on the control node, and installing them
on a worker would produce nightly failures.

SSH verified working via pinode_cluster_ed25519.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
ansible-playbook day0-infra-build.yml --tags manage_qnap --limit pinode-01 >>"$DETAIL" 2>&1 \
  || { echo "ansible run against pinode-01 failed - see $DETAIL"; exit 1; }
n="$(ssh -i "$HOME/.ssh/pinode_cluster_ed25519" -o BatchMode=yes gorttman@192.168.20.11 \
     "mount -t nfs,nfs4 | grep -c '^qnap:'" 2>/dev/null)"
[ "${n:-0}" -ge 9 ] && { echo "pinode-01 in inventory; $n QNAP mounts present"; exit 0; }
echo "inventory updated but pinode-01 shows only ${n:-0} QNAP mounts"; exit 1
