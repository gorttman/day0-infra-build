#!/bin/sh
# Self-resuming pause for the media mirror (added 2026-10-11).
# The media mirror cron line is commented out with a "#PAUSED ... # " prefix
# while big folders are moved off the backup disk (the mirror competes with
# the copy for the USB disk). This runs every 15 minutes from cron and puts the
# line back by itself - nobody has to remember:
#   - as soon as the folders being moved are gone from the backup disk, OR
#   - after 72 hours regardless, so a failed move cannot leave the mirror off.
# It does nothing at all when the mirror is not paused, so it is safe to leave
# installed. CRON and DRYRUN can be overridden for testing.
CRON=${CRON:-/etc/config/crontab}
STAMP=${STAMP:-/share/CACHEDEV1_DATA/.scripts/media-mirror-paused-at}
LOG=${LOG:-/share/CACHEDEV1_DATA/.scripts/qnap-snapshot.log}
V=${V:-/share/external/DEV3302_1/Data/Video}

grep -q '^#PAUSED .*qnap-data-snapshot-media-v2' "$CRON" 2>/dev/null || exit 0

pending=0
[ -d "$V/My Videos" ] && pending=1
for d in "Advanced Hand-cut Dovetails" "BENCH_CHISELS" "Hand-cut Dovetails 2.0" "METAL_INLAY_TECHNIQUES" "box making"; do
  [ -d "$V/$d" ] && pending=1
done
now=$(date +%s)
since=$(cat "$STAMP" 2>/dev/null || echo 0)
age=$((now - since))

if [ "$pending" = 0 ] || [ "$age" -ge 259200 ]; then
  sed -i 's/^#PAUSED [^)]*) # //' "$CRON"
  [ -n "$DRYRUN" ] || crontab "$CRON"
  rm -f "$STAMP"
  echo "[*] media mirror resumed automatically (moves finished: $([ "$pending" = 0 ] && echo yes || echo 'no, 72h limit')): $(date)" >> "$LOG"
fi
