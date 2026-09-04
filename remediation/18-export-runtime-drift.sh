#!/usr/bin/env bash
# Item 18 - detect exports that are configured but not actually live.
#
# roles/qnap_exports manages all six positionally-paired nfssetting
# sections correctly, and its handler already knows how to reload the
# server (/etc/init.d/nfs restart). The gap is that the handler is
# change-triggered: it fires when the config file needs editing, never
# when the file is already right but the running server has lost the
# export.
#
# That is exactly the failure mode behind the documented "QNAP reboot
# wipes external-disk NFS exports" incident - the reboot drops the
# runtime export, nfssetting still reads as correct, so every later run
# reports changed=0 and nothing repairs it. /syslog-archive sat dead this
# way for two months and took log-archiver down with it.
#
# Adds a runtime check that compares each managed export against
# `exportfs -v` and notifies the existing handler when one is missing.
#
# NOTE: applying this fires the NFS restart, which briefly interrupts
# every NFS client in the cluster. Run out of hours.
set -uo pipefail
D="$HOME/gm-dev/day0-infra-build"
cd "$D" || { echo "repo missing"; exit 2; }
if [ -f roles/qnap_exports/tasks/ensure_live.yml ]; then echo "runtime drift check already present"; exit 0; fi
[ -n "$(git status --porcelain roles/qnap_exports)" ] && { echo "tree dirty in role"; exit 2; }

cat > roles/qnap_exports/tasks/ensure_live.yml <<'YEOF'
################################################################################
# FILE: roles/qnap_exports/tasks/ensure_live.yml
################################################################################
---
# The other task files in this role reconcile /etc/config/nfssetting, the
# flash-backed config QTS reloads from on boot. They cannot see whether
# the *running* server actually serves those exports.
#
# Those two states genuinely diverge here. A QNAP reboot re-registers
# external/USB-volume exports fresh and can silently drop them, leaving
# nfssetting perfect and the export gone. Because every other task in
# this role is check-then-fix against the file, they all report no change
# and the restart handler never fires - so the export stays dead
# indefinitely. /syslog-archive was in exactly this state for two months,
# which is what kept log-archiver failing.
#
# exportfs -v is the running server's own view, so comparing against it
# catches the divergence the config-file checks structurally cannot.
- name: Read the running NFS export table
  ansible.builtin.raw: exportfs -v
  register: qnap_live_exports
  changed_when: false

- name: Notify a reload when a managed export is configured but not live
  ansible.builtin.debug:
    msg: >-
      Export {{ item.path }} is present in nfssetting but absent from the
      running server - reloading NFS to regenerate it.
  loop: "{{ qnap_managed_exports | default([]) }}"
  loop_control:
    label: "{{ item.path }}"
  when: item.path not in qnap_live_exports.stdout
  notify: Restart QNAP NFS service
YEOF

python3 - "$D" <<'PY'
import sys,os
d=sys.argv[1]
p=os.path.join(d,"roles/qnap_exports/tasks/main.yml"); s=open(p).read()
if "ensure_live.yml" not in s:
    s=s.rstrip("\n")+"""

# Last, deliberately: the three tasks above reconcile the config file, so
# any edit they make has already been written by the time this compares
# the file's intent against what the server is actually serving.
- name: Include runtime-liveness tasks
  ansible.builtin.include_tasks:
    file: ensure_live.yml
"""
    open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
ansible-playbook qnap-manage.yml --tags manage_qnap_exports --syntax-check >>"$DETAIL" 2>&1 \
  || { echo "syntax check failed"; exit 1; }
git add roles/qnap_exports/
git commit -q -m "Detect QNAP exports that are configured but not live

roles/qnap_exports reconciles nfssetting and already has a handler that
reloads NFS, but the handler is change-triggered: it fires when the file
needs editing, never when the file is correct and the running server has
lost the export.

Those states diverge in practice - a reboot re-registers external-volume
exports and can drop them, leaving nfssetting perfect. Every run then
reports changed=0 and nothing repairs it. /syslog-archive sat dead this
way for two months and kept log-archiver failing.

Compares each managed export against exportfs -v, the server's own view,
and notifies the existing handler when one is missing.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
echo "runtime drift check added (not applied - applying restarts NFS)"; exit 0
