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

This is fully scoped but **not implemented** — this role, `qnap_cron`,
and the "QNAP data snapshot script"/"QNAP backup cron" plays in
`qnap-manage.yml` are all still live and doing the QNAP-side thing as
of this entry. Retiring them needs to include manually removing the
already-pushed script and crontab entry from the QNAP itself, not just
deleting the Ansible tasks — Ansible only ever managed "ensure
present," never cleanup of retired state.
