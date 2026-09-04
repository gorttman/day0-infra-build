#!/usr/bin/env bash
# Item 5 - add /photos to the QNAP snapshot set.
#
# 170G, and in no backup at any tier. It is the folder-based source of
# truth behind the Immich external library, so losing it loses the photo
# library regardless of what Immich's own /immich share holds.
#
# It was never a deliberate exclusion: qnap_snapshot.yml documents its
# exclusions explicitly (/backup, /downloads, media/downloads, /cold,
# /Public) and /photos is not among them. It was simply missed.
#
# Risk considered: this job OOM'd the 984MB QNAP in August. rsync memory
# scales with file count, not bytes, and /photos is a shallow tree of
# large media files (~tens of thousands), so the added cost is small.
#
# Runs at 03:00. The first pass copies 170G and will take hours.
set -uo pipefail
V="$HOME/gm-dev/day0-infra-build/variables/play/qnap_snapshot.yml"
cd "$HOME/gm-dev/day0-infra-build" || { echo "repo missing"; exit 2; }
grep -q "name: photos" "$V" && { echo "photos already in snapshot sources"; exit 0; }
python3 - "$V" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old="  - name: vault\n"
new=("  # Added 2026-09-04. 170G and previously in no backup at any tier -\n"
     "  # missed rather than excluded, since every real exclusion is\n"
     "  # documented in the comment above. This is the folder-based source\n"
     "  # of truth for the Immich external library; the /immich share only\n"
     "  # holds Immich's own library/thumbs/upload trees.\n"
     "  - name: photos\n"
     "    path: /share/CACHEDEV1_DATA/photos\n"
     "  - name: vault\n")
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
[ $? -eq 0 ] || { echo "edit failed"; exit 1; }
git add "$V"
git commit -q -m "Add /photos to the QNAP snapshot set

170G with no backup at any tier. Not a deliberate exclusion - every real
exclusion is documented in that file's header and /photos is absent from
it. It is the source of truth for the Immich external library.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XHqsWBKamfbA8s81MyAaZH" >>"$DETAIL" 2>&1 || { echo "commit failed"; exit 1; }
git push -q origin main >>"$DETAIL" 2>&1 || { echo "push failed"; exit 1; }
# Push the regenerated script to the QNAP.
ansible-playbook qnap-manage.yml --tags manage_qnap_snapshot >>"$DETAIL" 2>&1 \
  || { echo "ansible run failed - see $DETAIL"; exit 1; }
if ssh -i "$HOME/.ssh/qnap_ansible_ed25519" -o BatchMode=yes admin@192.168.20.30 \
     "grep -q 'CACHEDEV1_DATA/photos' /share/CACHEDEV1_DATA/.scripts/qnap-snapshot.sh" 2>/dev/null; then
    echo "photos added; live QNAP script updated"; exit 0
fi
echo "committed but QNAP script does not mention photos"; exit 1
