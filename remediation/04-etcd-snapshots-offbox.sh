#!/usr/bin/env bash
# Item 4 - get etcd snapshots off k8smaster.
#
# k3s writes etcd snapshots every 12h to local disk and keeps 5. Nothing
# copies them anywhere: the only one on the QNAP was a manual
# post-conversion snapshot from 2026-08-30. Losing k8smaster's NVMe
# therefore loses all cluster state, which defeats the point of having
# snapshots at all.
#
# Deliberately a cron rsync, not a k3s server flag: changing
# --etcd-snapshot-dir restarts k3s and takes the API server down. This
# achieves the same durability with no restart.
#
# Mirrors the credentials-sync convention in this same role - mountpoint
# guard so a dead NFS mount fails loud instead of silently writing to
# local disk, and -rlpt because the QNAP export rejects -o -g.
#
# No --delete: k3s prunes to 5 locally, and mirroring that would throw
# away history the moment it rotates. Destination keeps 14.
set -uo pipefail
D="$HOME/gm-dev/day0-infra-build"
cd "$D" || { echo "repo missing"; exit 2; }
if sudo crontab -l 2>/dev/null | grep -q "etcd snapshots to QNAP"; then
    n="$(sudo sh -c 'ls -1 /mnt/backup/k8smaster-etcd-snapshots/etcd-snapshot-* 2>/dev/null | wc -l')"
    [ "${n:-0}" -gt 0 ] && { echo "already installed; $n etcd snapshots on the QNAP"; exit 0; }
    echo "cron installed but no snapshots on the QNAP"; exit 1
fi
python3 - "$D" <<'PY'
import sys,os
d=sys.argv[1]
p=os.path.join(d,"roles/qnap_client/defaults/main.yml"); s=open(p).read()
if "etcd_snapshot_backup_dest" not in s:
    anchor="credentials_backup_dest: /mnt/backup/k8smaster-credentials\n"
    assert anchor in s
    s=s.replace(anchor, anchor+
      "\n# k3s writes etcd snapshots here every 12h and keeps 5. They never left\n"
      "# this host until 2026-09-04, so an NVMe failure took all cluster state\n"
      "# with it despite snapshots existing.\n"
      "etcd_snapshot_src: /var/lib/rancher/k3s/server/db/snapshots\n"
      "etcd_snapshot_backup_dest: /mnt/backup/k8smaster-etcd-snapshots\n"
      "etcd_snapshot_backup_keep: 14\n",1)
    open(p,'w').write(s)

p=os.path.join(d,"roles/qnap_client/tasks/main.yml"); s=open(p).read()
if "etcd snapshots to QNAP" not in s:
    task = '''
# etcd snapshots were the one backup stream with no off-box copy at all
# (found 2026-09-04): k3s kept 5 locally and nothing ever moved them, so
# the snapshots would have died with the disk they protect against.
# Same mountpoint-guard shape as the credentials sync above - a silently
# dead /mnt/backup must fail loud, not fill local disk. No --delete: k3s
# prunes to 5 locally and mirroring that would discard history on every
# rotation, so the destination prunes on its own count instead.
- name: Install off-box sync of etcd snapshots to the QNAP
  ansible.builtin.cron:
    name: "Sync k3s etcd snapshots to QNAP backup share"
    minute: "0"
    hour: "5"
    job: >-
      if mountpoint -q {{ etcd_snapshot_backup_dest | dirname }}; then
      mkdir -p {{ etcd_snapshot_backup_dest }} &&
      rsync -rlpt {{ etcd_snapshot_src }}/ {{ etcd_snapshot_backup_dest }}/
      >> /var/log/etcd-snapshot-sync.log 2>&1 &&
      ls -1t {{ etcd_snapshot_backup_dest }}/etcd-snapshot-* 2>/dev/null
      | tail -n +{{ etcd_snapshot_backup_keep | int + 1 }} | xargs -r rm -f; else
      echo "$(date -Iseconds) ERROR: {{ etcd_snapshot_backup_dest | dirname }} is not mounted - refusing to sync, this would otherwise write to local disk" >> /var/log/etcd-snapshot-sync.log; fi
'''
    s = s.rstrip("\n") + "\n" + task
    open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add roles/qnap_client/
git commit -q -m "Sync k3s etcd snapshots off-box to the QNAP

etcd snapshots were the only backup stream with no off-box copy: k3s kept
5 on local disk and nothing moved them, so an NVMe failure would have
destroyed the snapshots along with the cluster they protect. The single
copy on the QNAP was a manual one from the 2026-08-30 conversion.

Implemented as a cron rsync rather than --etcd-snapshot-dir because
changing that flag restarts k3s and drops the API server.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
ansible-playbook day0-infra-build.yml --tags manage_qnap --limit k8smaster >>"$DETAIL" 2>&1 \
  || { echo "ansible run failed - see $DETAIL"; exit 1; }
sudo crontab -l 2>/dev/null | grep -q "etcd snapshots to QNAP" || { echo "cron entry not installed"; exit 1; }
# Seed it now rather than waiting for 05:00, and prove it actually works.
sudo mkdir -p /mnt/backup/k8smaster-etcd-snapshots
sudo rsync -rlpt /var/lib/rancher/k3s/server/db/snapshots/ /mnt/backup/k8smaster-etcd-snapshots/ >>"$DETAIL" 2>&1 \
  || { echo "seed rsync failed - see $DETAIL"; exit 1; }
n="$(sudo sh -c 'ls -1 /mnt/backup/k8smaster-etcd-snapshots/etcd-snapshot-* 2>/dev/null | wc -l')"
[ "$n" -gt 0 ] && { echo "cron installed; $n etcd snapshots now on the QNAP"; exit 0; }
echo "cron installed but no snapshots landed"; exit 1
