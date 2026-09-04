#!/usr/bin/env bash
# Item 6 - make the restore path complete and documented.
#
# restore.sh already existed and already handled postgres, sealed-secrets
# and qnap-data. The audit wrongly reported "no Postgres restore step";
# the real gap was narrower and in three parts:
#   1. docs/rebuild-runbook.md never mentions restore.sh at all, so a
#      rebuilder following the runbook never learns it exists.
#   2. The SSH private keys now backed up to credentials/ssh have no
#      restore path - without them a rebuilt controller cannot reach the
#      QNAP, and group_vars/qnap.yml expects them at ~/.ssh.
#   3. day2-services/adhoc/ holds manifests that are deliberately outside
#      every ArgoCD sync path. Its README said "apply by hand", which is
#      exactly the kind of step that gets skipped.
#
# Adds ssh-keys and adhoc subcommands, documents the whole chain, and
# proves the postgres path works using restore.sh's own --to scratch
# mechanism rather than asserting it.
set -uo pipefail
D="$HOME/gm-dev/day0-infra-build"
T="$D/roles/backup_restore/templates/restore.sh.j2"
cd "$D" || { echo "repo missing"; exit 2; }
if grep -q "cmd_ssh_keys" "$T"; then echo "restore wiring already present"; exit 0; fi
[ -n "$(git status --porcelain roles/backup_restore docs)" ] && { echo "tree dirty in target paths"; exit 2; }

python3 - "$D" <<'PY'
import sys,os
d=sys.argv[1]
t=os.path.join(d,"roles/backup_restore/templates/restore.sh.j2"); s=open(t).read()

s=s.replace("""  restore.sh qnap-data <source> --to <path>  Restore into a scratch path instead - safe test, no confirmation needed
""","""  restore.sh qnap-data <source> --to <path>  Restore into a scratch path instead - safe test, no confirmation needed
  restore.sh ssh-keys [--dry-run]            Restore SSH private keys to ~/.ssh (needed before any QNAP-targeting play)
  restore.sh adhoc [--dry-run]               Apply manifests kept outside ArgoCD (day2-services/adhoc/)
""",1)

anchor = 'case "${1:-}" in'
new_cmds = '''# --- ssh keys -------------------------------------------------------------
# A rebuilt controller has no SSH keys, and group_vars/qnap.yml points
# ansible_ssh_private_key_file at ~/.ssh/qnap_ansible_ed25519. Without
# this, every QNAP-targeting play fails at connection time and the QNAP
# half of the rebuild simply cannot run. Keys reach the QNAP through the
# nightly credentials/ rsync in roles/qnap_client.
cmd_ssh_keys() {
  local dryrun="" src="{{ credentials_backup_dir }}/ssh" dest="$HOME/.ssh"
  [ "${1:-}" = "--dry-run" ] && dryrun=1
  if [ ! -d "$src" ]; then
    echo "No SSH key backup at $src" >&2; return 1
  fi
  local n=0
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    local base; base="$(basename "$f")"
    if [ -n "$dryrun" ]; then
      echo "would restore $base -> $dest/$base"
    else
      mkdir -p "$dest"; chmod 700 "$dest"
      cp -p "$f" "$dest/$base"
      case "$base" in *.pub) chmod 644 "$dest/$base" ;; *) chmod 600 "$dest/$base" ;; esac
    fi
    n=$((n+1))
  done
  echo "${dryrun:+would restore }${n} SSH key file(s)"
}

# --- adhoc manifests ------------------------------------------------------
# day2-services/adhoc/ holds manifests that are real and applied but
# deliberately outside every ArgoCD sync path - currently the
# immich-tagging SealedSecret, which is sealed for the default namespace
# because the ad-hoc Jobs that consume it live there. Nothing syncs these,
# so a rebuild must apply them explicitly.
cmd_adhoc() {
  local dryrun="" dir="$HOME/gm-dev/day2-services/adhoc"
  [ "${1:-}" = "--dry-run" ] && dryrun=1
  if [ ! -d "$dir" ]; then
    echo "No adhoc directory at $dir" >&2; return 1
  fi
  local n=0
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    [ -e "$f" ] || continue
    if [ -n "$dryrun" ]; then echo "would apply $(basename "$f")"
    else kubectl apply -f "$f" || return 1
    fi
    n=$((n+1))
  done
  echo "${dryrun:+would apply }${n} adhoc manifest(s)"
}

'''
assert anchor in s
s=s.replace(anchor, new_cmds+anchor,1)
s=s.replace('  qnap-data) shift; cmd_qnap_data "$@" ;;\n',
            '  qnap-data) shift; cmd_qnap_data "$@" ;;\n'
            '  ssh-keys) shift; cmd_ssh_keys "$@" ;;\n'
            '  adhoc) shift; cmd_adhoc "$@" ;;\n',1)
open(t,'w').write(s)

p=os.path.join(d,"docs/rebuild-runbook.md"); s=open(p).read()
if "restore.sh" not in s:
    note = '''
## Step 8 - Restore data

Steps 1-7 rebuild infrastructure and let ArgoCD redeploy the app fleet.
They restore no data. `/usr/local/bin/restore.sh` handles that, deployed
by `roles/backup_restore` during Step 3.

Run these in order - `ssh-keys` first, because every QNAP-targeting play
and every other restore stream depends on reaching the NAS:

    restore.sh list                 # what is restorable right now
    restore.sh ssh-keys             # ~/.ssh, needed before any QNAP play
    restore.sh sealed-secrets       # stage the newest key backup
    restore.sh postgres             # all databases, newest generation
    restore.sh adhoc                # manifests kept outside ArgoCD
    restore.sh qnap-data <source>   # per-export file restore

Every real restore asks for confirmation. To rehearse without touching
anything live, use `--dry-run`, or restore into a scratch target with
`postgres <db> --to <scratch-db>` / `qnap-data <source> --to <path>`.

Not covered by restore.sh: etcd. Snapshots are synced to
`/mnt/backup/k8smaster-etcd-snapshots` by a cron entry in
`roles/qnap_client`, and are restored with `k3s server
--cluster-reset --cluster-reset-restore-path=<snapshot>`, which is a
cluster-level operation rather than a data restore.
'''
    s = s.rstrip("\n") + "\n" + note
    open(p,'w').write(s)
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add roles/backup_restore/templates/restore.sh.j2 docs/rebuild-runbook.md
git commit -q -m "Wire SSH keys, adhoc manifests and restore.sh into the rebuild path

restore.sh already handled postgres, sealed-secrets and qnap-data, but
the rebuild runbook never mentioned it, so following the runbook never
led anyone to it.

Adds two missing links. ssh-keys restores the private keys now backed up
to credentials/ssh - without them group_vars/qnap.yml cannot authenticate
and the entire QNAP half of a rebuild is unreachable. adhoc applies
day2-services/adhoc/, whose README previously said to apply it by hand.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
ansible-playbook day0-infra-build.yml --tags manage_backup_restore --limit k8smaster >>"$DETAIL" 2>&1 \
  || { echo "ansible run failed - see $DETAIL"; exit 1; }
sudo grep -q "cmd_ssh_keys" /usr/local/bin/restore.sh || { echo "deployed restore.sh lacks new commands"; exit 1; }
# Seed the credentials sync rather than waiting for its 04:30 cron: the
# ssh/ subdirectory was added today and has not propagated to the QNAP
# yet, so the restore source would not exist to verify against.
sudo sh -c 'if mountpoint -q /mnt/backup; then rsync -rlpt --delete '"$D"'/credentials/ /mnt/backup/k8smaster-credentials/; fi' >>"$DETAIL" 2>&1 \
  || { echo "credentials seed rsync failed"; exit 1; }
sudo /usr/local/bin/restore.sh ssh-keys --dry-run >>"$DETAIL" 2>&1 || { echo "ssh-keys dry-run failed"; exit 1; }
sudo /usr/local/bin/restore.sh adhoc --dry-run >>"$DETAIL" 2>&1 || { echo "adhoc dry-run failed"; exit 1; }
# Prove the postgres path for real, into a scratch database.
sudo /usr/local/bin/restore.sh postgres books --to books_restore_probe >>"$DETAIL" 2>&1 \
  || { echo "scratch postgres restore FAILED - see $DETAIL"; exit 1; }
rows="$(sudo kubectl exec -n postgres statefulset/postgres -- psql -U postgres -d books_restore_probe -tAc \
        "select count(*) from information_schema.tables where table_schema='public';" 2>/dev/null | tr -d ' ')"
sudo kubectl exec -n postgres statefulset/postgres -- psql -U postgres -tAc \
     "drop database if exists books_restore_probe;" >>"$DETAIL" 2>&1
[ "${rows:-0}" -gt 0 ] && { echo "restore path wired and proven (scratch restore made $rows tables)"; exit 0; }
echo "scratch restore produced no tables"; exit 1
