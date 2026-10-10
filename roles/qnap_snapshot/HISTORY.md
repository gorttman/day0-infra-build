# qnap_snapshot: build history, mistakes, and fixes

Same convention as `cloudflare-tf/HISTORY.md` and `unifi_tf_apply/HISTORY.md`
— if something looks weird in the code, the answer is probably in here.

## 1. The QNAP OOM crash and its actual root cause (2026-08-18)

The QNAP had an unclean crash at ~04:15 while this role's nightly cron job
(03:00, `qnap-data-snapshot`) was mid-run. Confirmed via the crashed
boot's own `kmsg.1`: kernel OOM-killer fired with `slab_unreclaimable` at
712MB of the QNAP's ~1GB total RAM — dentry/inode cache from tree-walks,
not process memory — and `qnap-snapshot.sh` plus 3 live `rsync`
processes were sitting in the process list at the exact moment of the
kill.

Root cause, once traced through: `rsync --link-dest` has to `stat()`
every file in *both* the live source tree and the previous day's
snapshot tree to decide what changed — even for a source with zero
changes, that's two full metadata walks. This script ran all 8 sources
(books, vault, immich, paperless, inbox, media, pihole, calibre-web)
back-to-back with zero pacing between them, so dentry/inode cache
pressure just accumulated across all 8 with nothing ever giving the
kernel a chance to reclaim. File *count* is what matters here, not byte
volume — a photo/media library's worst case is exactly this shape.

The crash cascaded into two more incidents entirely unrelated to this
role's own logic (QNAP's onboard SATA controller losing its 6 RAID
drives on the unclean reboot, eth0's DHCP lease drifting to a new
address) — see project memory `qnap-crash-aug18-recovery` for that part,
not duplicated here since it's not this role's fault, just its blast
radius.

## 2. Fix, part 1: producer-driven change detection (2026-08-18)

Tried "check if anything changed before syncing" as a tree-walk-based
skip first, then realized it doesn't actually save anything — detecting
"nothing changed" this way costs exactly the same full tree-walk as
just doing the backup. The only way detection is actually cheap is if
the *producer* signals it: each source's own app already knows the
instant it writes something, so it touches a `.snapshot-pending` marker
file at the source root, and this script's job shrinks to a single
`stat()` check per source instead of a diff.

Implemented for `books` only so far (the producer hook lives in
`day2-services/apps/books-pipeline/books_pipeline.py`, not in this
repo) — the other 7 sources still sync unconditionally every night
until they get the same hook. Fixing this also required making
weekly/monthly promotion per-source (look up each source's own most
recent daily generation, not assume `$TODAY_DIR` has everything) —
otherwise a source skipped on a Sunday or the 1st would silently drop
out of that week's/month's generation.

## 3. Fix, part 2: move execution off the QNAP entirely (decided, not built)

Given the actual root cause is "expensive tree-walk on a box with
almost no RAM to spare," the more durable fix is to stop running this
on the QNAP at all — move it to a k8s CronJob on a node with real
headroom (k8smaster), matching how `postgres-backup-cronjob.yml`
already reaches the `/backup` export (`hostPath` + `nodeSelector:
k8smaster`, NOT a pod-level `nfs:` volume — that export is confirmed
broken for kubelet's own NFS volume mechanism, see that file's own
header comment). Source exports can stay plain pod-level `nfs:`
volumes, same pattern as `books-pipeline`'s own CronJob.

This is fully scoped but **not implemented** — still true as of this
entry (2026-10-03). This role, `qnap_cron`, and the "QNAP data
snapshot script"/"QNAP backup cron" plays in `qnap-manage.yml` are all
still live and doing the QNAP-side thing. Retiring them needs to
include manually removing the already-pushed script and crontab entry
from the QNAP itself, not just deleting the Ansible tasks — Ansible
only ever managed "ensure present," never cleanup of retired state.

## 4. Fix, part 2b: per-source cron jobs, since part 2 (move off QNAP
## entirely) still wasn't built (2026-09-22)

This role's own predicted failure mode from #1 happened again — this
time coinciding with (and likely aggravated by) heavy concurrent
inbound writes from arr-stack, which the original script had zero
awareness of or throttling against. Part 2 above (move execution off
the QNAP to a k8s CronJob with real RAM headroom) is still the more
durable eventual fix and remains unbuilt, but in the meantime this
closes the same class of failure from the QNAP side:

- **Split into one cron entry per source** (`qnap-snapshot.sh <source>`,
  or `--prune`) instead of one script looping through all of them.
  Pacing via `sleep` was considered and rejected — a sleeping process
  is still resident and only gives the kernel an *opportunity* to
  reclaim cache; a fully exited process forces it. 10 separate cron
  triggers, `flock`-serialized against the same lock file, get a hard
  guarantee instead of a hope.
- **Explicit `sync && echo 2 > /proc/sys/vm/drop_caches`** at the end
  of every per-source run — directly forces the dentry/inode reclaim
  that #1's root cause needed, rather than relying on the kernel's own
  (lazy, not guaranteed promptly on a ~1GB box) reclaim timing.
- **`ionice -c2 -n7` (best-effort, lowest priority), not `-c3` (idle)**
  — idle only gets I/O when the disk is completely quiet, which under
  arr-stack's sustained writes may never happen, so the job could
  starve to near-zero throughput and effectively never finish.
  Best-effort still competes, just at the bottom of the queue — slows
  down under contention, doesn't stall.
- **`nice -n19`** (lowest CPU priority) and **`rsync --bwlimit`**
  (default 20MB/s, `qnap_snapshot_bwlimit_kbps`) alongside it, so the
  job doesn't burst back to full speed the instant a gap opens up.
- **Schedule moved to start at 23:59** (low real usage then, per
  direct ask) with 20-minute gaps between each of the 10 entries,
  landing at 23:59-02:59. This pushed `postgres-backup` from 02:00 to
  03:30 (day2-services `apps/postgres/postgres-backup-cronjob.yml`) to
  keep those 20-minute recovery gaps intact rather than compressing
  them to fit around postgres-backup's old slot — the credentials
  rsync at 04:30 (`roles/qnap_client`) still has an hour of margin
  after that.

**This entire fix turned out to be non-functional in production from
the day it was committed — see #5.**

## 5. #4 silently did nothing for 11 days: `flock`, `ionice`, `nice`
## don't exist on this BusyBox (discovered + fixed 2026-10-03)

Found while investigating the backup-status dashboard showing the QNAP
data snapshot stream critical with zero generations. `qnap-snapshot.log`
showed exactly one line repeated on every single cron trigger since
2026-09-22: `/bin/sh: flock: command not found`. Confirmed live over
SSH: `which flock ionice nice` on the QNAP returns nothing, and
`busybox --list` has no applets for any of the three either - they are
simply not present on this device, at all, in any form. Every one of
the 10 per-source cron entries from #4 died on its first line before
ever reaching rsync. The last real, successful "QNAP data snapshot
complete" line in the log is from 2026-09-17, five days *before* #4
was even written - meaning this backup stream has produced zero output
for 11 consecutive days without anyone noticing, because the failure
mode is silent (cron has no `MAILTO` configured, and nothing watches
this specific log for the `command not found` pattern).

Root cause of why this got committed broken: the `ionice`/`nice`/
`flock` story in #4 was written and reasoned through carefully but
never actually verified live against the real device before being
pushed - a bug in process, not just in code; "confirmed live" claims
elsewhere in this file were genuinely checked, this one wasn't.

**Fix:**
- **`flock` replaced with a plain `mkdir`-based lockdir inside the
  script itself**, not in the cron command line. `mkdir` is atomic on
  any POSIX filesystem and needs no external binary. Same "wait, don't
  skip" semantics `flock` would have had, plus stale-lock recovery
  (checks whether the PID that holds the lock is still alive, which
  `flock` itself doesn't give you for free) - a genuine improvement,
  not just a workaround.
- **`ionice` and `nice` dropped entirely.** `rsync --bwlimit` is the
  only one of the three throttle mechanisms that was ever real; it's
  the only one kept.
- **Found, while investigating, a second complete design for the same
  2026-09-18 incident sitting uncommitted in the working tree** - a
  Jellyfin-session-aware throttle (`qnap_stream_watcher` role, polls
  `/Sessions` every 2 min, flag file this script reads) that's
  strictly better than #4's static always-on throttle, plus a mid-run
  re-check for the long-running `photos` source. That draft had
  independently confirmed the same missing-`ionice`/`flock` finding
  back on 2026-09-18 and noted it as a "known gap" rather than fixing
  it - it was never committed, and #4 was built from scratch four days
  later without reusing it. Folded into this fix rather than discarded:
  it's genuinely good, and there's no reason to rebuild it a third
  time. See `variables/play/qnap_stream_watcher.yml` and the "QNAP
  stream-aware backup throttle" play in `qnap-manage.yml`.
- **Cron entries renamed** (`-v2` suffix) rather than edited in place -
  `qnap_cron`'s idempotency check only ever adds a missing `name`, it
  never updates an existing entry's command, so changing the command
  without changing the name would have left the old, broken lines
  permanently stuck in the live crontab alongside new ones. The old
  un-suffixed entries were removed from `/etc/config/crontab` by hand
  over SSH as part of deploying this fix - if a future change needs to
  edit a cron command again, remember to do the same or bump the
  suffix again.
- **photos and media moved to the end of the schedule**, after prune -
  see #6, they can now run for hours in `mode: mirror` and the shared
  lock would otherwise hold up every stable/quick source behind them.

**How to apply:** if the backup-dashboard ever shows this stream
critical again, check `qnap-snapshot.log` for `command not found`
before assuming it's a QNAP-reachability or disk-space problem - a
missing binary on a BusyBox image is a real, recurring failure class
here, not a one-off.

## 6. Interim mirror mode for actively-migrating sources (2026-10-03)

Generational `--link-dest` snapshotting assumes the source is roughly
stable between runs - true for books/vault/paperless/inbox/pihole/
calibre-web, false for `photos` (mid photo-library migration, see
project memory `project_immich_wrong_year_diagnosis`) and `media`
(constant inbound writes from arr-stack). For those two, a nightly
generational diff means re-walking a tree that's changed enormously
since yesterday, every night, which is exactly the shape of both the
2026-08-18 and 2026-09-18/21 incidents.

Added `mode: mirror` as a per-source option
(`variables/play/qnap_snapshot.yml`): a source in this mode gets a
flat, persistent `rsync -a` into `$BACKUP_ROOT/mirror/<name>/` instead
of a dated `--link-dest` generation - no hardlink-tree rebuild, no
`--delete` (so a mid-migration rename/move never removes the only
backup copy before it's re-landed somewhere else), one destination
that just keeps catching up run over run. Weekly/monthly promotion is
skipped entirely for a mirrored source - there's no "generation" to
promote until it's back in generational mode. `--stats` is always
passed to rsync now (both modes), so `qnap-snapshot.log` shows how many
files/bytes moved each run without any extra tree-walk cost.

**Known gap, tested and accepted rather than fixed:** killing a
`long_running` mode: mirror run mid-flight (manually, not something the
nightly cron ever does on its own) reliably stops two of the three
rsync worker processes it spawns, but the third can land in
uninterruptible disk-wait (D state) on a write to the USB backup disk
and stay there until that I/O returns - no signal, including `-9`,
reaches it before then. Same class of thing as the hard-NFS-hang case
in project memory `feedback_hard_nfs_hang_blocks_sigkill`, just against
the local USB disk instead of an NFS mount. Confirmed live 2026-10-03:
it clears on its own within roughly a minute once the stuck write
completes; the lock is still released immediately regardless, so a
fresh run is free to start without waiting on it. Not pursued further -
nothing in userspace can do better here, and a device reboot (the only
other thing that would need this) clears everything anyway.

**How to flip a source back to generational mode**, once it's caught
up: watch `qnap-snapshot.log` for that source's "Number of regular
files transferred" line - once it's staying near zero for a few
consecutive nights, remove `mode: mirror` from its entry in
`variables/play/qnap_snapshot.yml` and re-run
`qnap-manage.yml --tags manage_qnap_snapshot`. The first generational
run afterward won't have a `--link-dest` baseline yet (the mirror
directory isn't wired in as one), so it'll do one full-cost copy into
that day's generation same as a brand new source would - a deliberate
simplification rather than extra complexity to chain the mirror
directory in as the first baseline, since this is a one-time cost paid
once per source, not a recurring one.

## 7. Weekly/monthly promotion failed on every source (found 2026-10-04)

Symptom: `qnap-snapshot.log` showed `rsync: mkdir ".../weekly/2026-W40/<source>"
failed: No such file or directory` after each source's daily run. The daily
tier was fine; the weekly tier had no data.

Cause: the QNAP's rsync 3.0.7 has no `--mkpath`, and it creates only the last
path component. The `weekly/<week>/` and `monthly/<month>/` parents did not
exist, and the script never created them.

Fix: `mkdir -p` the destination before each promotion rsync. Sources that
missed their promotion on 2026-10-04 (before the fix) are not backfilled;
the next Sunday promotes them.

## 8. A multi-TB mirror run starves the nightly sources (found 2026-10-05)

Symptom: the first photos mirror run started 02:44 and was still going at
07:00 (259 of 708 GB). The media job, due 02:59, was alive but idle in the
lock's 15-second retry loop. It retries forever.

Cause: the script allows one source at a time (the lock exists because
concurrent rsyncs ran the 1 GB QNAP out of memory). A mirror holds the lock
for its whole run. Photos needs about 13 hours, media is multi-TB and needs
days at the 20 MB/s cap. While a mirror holds the lock, the 23:59 nightly
sources (books, vault, paperless, immich, inbox, pihole, calibre-web) wait
behind it, and which waiting job wins the lock is random, not queue order.

Fix:
- Each mirror run stops after `qnap_snapshot_mirror_max_hours` (7). Checked
  inside `run_rsync`'s wait loop, which already wakes every few minutes, so
  no `timeout` binary is needed (BusyBox here has no flock/ionice/nice either).
  The copy is additive, so the next night skips what is already copied. A
  time-boxed stop exits 0 and logs "mirror paused at its time limit".
- Mirror runs use `--partial-dir=.rsync-partial`, so a half-copied file is
  kept and resumed, not left as a stray temp file and restarted. Tested.
- The script is now pushed to `qnap-snapshot.sh.new` and `mv`'d into place.
  The old `cat >` rewrote the file in place, and a running instance (a mirror
  runs for hours) reads its script lazily, so it would have resumed in the
  middle of a different file.

Tested on the QNAP in a sandbox copy with its own lock, a scratch source and
a 12-second limit: stopped on time, exit 0, partial kept, lock released, real
lock untouched; a second run resumed and produced a byte-identical copy and
removed the partial directory.

Timing: photos starts 02:39, media 02:59, run in turn, two 7-hour runs end
by about 16:00, clear of the 23:59 start. Both resume nightly until caught
up, then flip back to generational mode (see #6).

Deploy note: a run already waiting for the lock holds the OLD script. Kill
it with `kill -9`, never plain `kill`: its EXIT trap runs `release_lock`,
which does `rm -rf` on the lock directory, and that would free a lock held
by a different, running job.

## 9. books had no backup generation at all (found 2026-10-05)

Symptom: no daily generation contained `books`; the newest books copy was in
weekly W34 (late August); the Sunday weekly promotion for books logged
nothing; the weekly tier had no W35 onward for books.

Cause, three parts that together hid it:
- `books` is a flag-file source: it syncs only when `.snapshot-pending`
  exists. On a night with no change it is skipped and creates no `books`
  directory in that day's daily generation.
- Prune keeps the newest 7 daily DIRECTORIES regardless of contents. After a
  week of skipped nights, the last directory that contained books aged out.
- Weekly promotion copies "this source newest daily generation". With none,
  `SRC_DAILY_DIR` is empty and the promotion silently does nothing. And the
  flag stayed absent, so books was never synced again.
Also, the rsync baseline was "the newest daily directory, if it has this
source", so even when books did sync it copied the whole tree again.

Fix (all tested in a sandbox on the QNAP with the rendered script):
- Baseline for `--link-dest` is the source own newest generation across daily,
  then weekly and monthly. First sync after the gap hardlinked unchanged files
  against W34 and copied only changed and new files.
- A flag-file source with no daily generation at all is flagged automatically,
  and the flag is set BEFORE the copy, so an interrupted run retries the next
  night (a half-copied directory cannot count as a generation).
- Prune never deletes the newest daily directory that contains a given source.
  Tested: books present only in the oldest of 10 directories survived a prune
  with keep=7 while the surplus directories were removed.

First effect: tonight 23:59 the books job finds no daily generation, flags
itself and syncs against W34. Expect the log line "books has no daily
generation yet - flagging it for a full sync". After that, skipped nights
leave the generation in place, and the Sunday promotion has something to
promote (first real weekly promotion for every source: Sunday 2026-10-11).

## 10. Mirror runs leave a last-run marker (2026-10-05)

The reports backup page judged every source by its newest DAILY generation.
A mirror-mode source (photos, media) has none by design, and the old photos
generation from September (kept forever by the #9 prune protection) made the
page show photos as 14 days stale and the QNAP stream critical permanently.

Fix: each mirror run touches `mirror/<source>/.last-run` when it ends,
whether it completed or stopped at its time limit. A run that fails never
reaches that line, so a broken mirror still goes stale on the page. The page
reads the marker (day2-services apps/reports, reports-backups-cm.yml).
Sandbox-tested: marker created, real lock untouched. A mirror run always
lasts at least one recheck interval (120 s) even for a tiny copy; that is the
existing poll loop, not a fault.

## 11. Changed-only sources get a monthly floor (2026-10-11)

`books` is copied only when the producer flags a change, so a quiet library
could go months with no new generation and the report page showed it critical
after 4 days even though nothing was wrong. Two changes: (1) the script now
flags a flag-file source for a full sync when its newest daily generation is
28+ days old, giving at least one backup a month; (2) the reports page labels
each source Nightly / Mirror / Changed-only + monthly and judges the last type
on a 31-day warn / 35-day critical scale. Logic sandbox-tested locally (6-day
generation: not due; old generation: flagged). Deploy: `ansible-playbook
qnap-manage.yml --tags manage_qnap_snapshot` (the push is a raw task, so
--check skips it).

## 12. Media mirror pause that resumes itself (2026-10-11)

The media mirror was paused (its cron line commented with a "#PAUSED" prefix)
so a 112 GB move off the backup disk was not fighting it for the USB disk. A
pause that someone has to remember to undo is how things stay off, so
`files/media-mirror-resume.sh` runs every 15 minutes from cron and restores the
line by itself once the folders being moved are gone, or after 72 hours
whichever comes first. Doing nothing when not paused, it is safe to leave
installed. Also found: the mirror script's cleanup (release_lock) kills any
rsync whose command line contains the mirror source path, which includes
unrelated copies INTO media/ - stopping the mirror killed a woodworking copy
mid-file (source untouched, rerun resumed). Do not run other rsyncs into media/
while a media mirror stops.
