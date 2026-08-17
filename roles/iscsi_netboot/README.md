# iSCSI Netboot Role

Sibling to `nfs_netboot`, not a replacement for it. Boots a node's *entire*
root filesystem over iSCSI instead of NFS — one shared read-only golden
image (squashfs) plus a per-node writable layer, combined via a real
`overlay` mount. Built in response to `pinode-01`'s NFS-root tmpfs
disk-pressure problem (see `docs/storage-ha-proposals.md` item 2 and
project memory `pinode_tmpfs_storage`) — overlayfs cannot sit on NFS, but
it works cleanly on iSCSI-backed block devices, confirmed on real hardware
during the Phase 0 spike (2026-08-11).

## Why NFS-root in the first place, and why iSCSI now

NFS-root was the original choice for diskless boot, not an accident or a
placeholder — it's a simpler mental model to reach for first (one export,
mount it, done), and it's what the PXE/diskless pipeline was originally
built around. Nothing about that choice was wrong at the time; it worked,
and it's still what every node except the ones deliberately converted
here continues to boot from.

Two things specifically weren't known when that original choice was made,
and both only became clear during this investigation (2026-08-11):

1. That overlayfs's incompatibility with NFS would eventually force a
   workaround (the tmpfs container-storage carve-out) rather than being a
   one-off inconvenience — this only became a real, recurring problem
   once actual workloads (Jellyfin's image size) hit it.
2. **How capable this specific QNAP already was.** QTS 4.3.4 ships a real,
   scriptable iSCSI target stack (`qcli_iscsi`, the same raw-SSH
   CLI-automation pattern already used for `qnap_backup_dirs`/
   `qnap_exports`) that was sitting there, already running, the whole
   time — this wasn't a purchase or an upgrade, just unused capability
   that nobody had gone looking for yet.

In hindsight, iSCSI could plausibly have been the right choice from the
start — it gives real overlayfs support with no tmpfs workaround needed
at all. Familiarity with NFS and not yet knowing what the QNAP could
actually do were the real reasons it wasn't, not a technical argument
against iSCSI. Worth writing down plainly rather than glossing over,
since it's the kind of thing worth checking *before* building the next
piece of infrastructure, not just after hitting a wall with the current
one.

**Status: Phase 1 (code scaffolding). Not yet run against a real node.**
Phase 0's spike proved the underlying mechanism (kernel iSCSI transport,
QNAP target/LUN creation, `open-iscsi` on this exact ARM64 kernel, real
overlayfs on an iSCSI block device) all work — but that was a manual,
post-boot test with no boot-order changes. The custom two-target
initramfs script this role installs (`files/iscsi-overlay-root`) has
**not** been booted on real hardware yet. Treat it as a reasoned first
draft, not proven code, until a real node has actually booted from it.

## Why NFS-root isn't being replaced

Diskless/PXE netboot itself stays — no SD cards, centralized image
management, the whole reason this project's PXE infrastructure exists.
Only the storage transport underneath the per-node writable layer (and,
if this proves out, the OS root itself) changes from NFS to iSCSI. Every
node not explicitly converted keeps booting NFS-root exactly as today,
indefinitely — iSCSI is opt-in per node via `convert_iscsi_node`, never a
fleet-wide default.

## Rollback, by design

Every per-node file this role writes lands in the *same* TFTP directory
`nfs_netboot` already owns (`tftp_root/<node-name>/`). Rolling a node back
is `rollback_iscsi_node` — it just re-renders that node's `cmdline.txt`
via `nfs_netboot`'s own template, the exact same render used for every
NFS-mode node. No separate rollback code path to drift out of sync. The
node's QNAP LUN/target are left in place on rollback (cheap to keep,
needed again if it's converted forward later) — remove them by hand via
`qcli_iscsi` only when actually decommissioning iSCSI for that node, not
for a routine test rollback.

Neither `convert_iscsi_node` nor `rollback_iscsi_node` reboots the node —
config changes take effect on next reboot, same as every other netboot
config change in this project.

## Prerequisites

- `credentials/qnap-admin-password.txt` (gitignored, not committed) —
  the QTS **admin account password**, not an SSH key. QCLI enforces its
  own session auth independent of SSH key access to the QNAP — confirmed
  the hard way during Phase 0, being SSH'd in as `admin` is not enough.
- QNAP pool has **zero free space at the pool level** today (one static
  volume already claims the whole 21.8TB pool) — every LUN this role
  creates is `LUNType=File` against `volumeID: 1`, never `Block`. If the
  pool layout ever changes, review `roles/iscsi_netboot/defaults/main.yml`.

## Usage

```bash
# One-time (and after any golden-image update): build + publish the
# shared image. Installs open-iscsi and the custom overlay-root script
# into the golden tree via chroot first (see install_iscsi_initiator.yml
# for why chroot, not live apt-install into a booted node's /var).
ansible-playbook day0-infra-build.yml --tags manage_iscsi

# Convert one already-known node. Node identity is explicit, not
# auto-discovered — see convert_node.yml's header comment for why.
ansible-playbook day0-infra-build.yml --tags convert_iscsi_node \
  -e node_name=pinode-01 -e node_mac_suffix=2793f1 \
  -e node_initiator_iqn=iqn.2026-08.com.i3sec:pinode-01

# Roll it back
ansible-playbook day0-infra-build.yml --tags rollback_iscsi_node \
  -e node_name=pinode-01
```

## What's real vs. what's a first draft

**Proven on real hardware (Phase 0, 2026-08-11):** kernel iSCSI transport
loads clean on the RPi5 kernel; `open-iscsi` installs and runs on this
ARM64 build; `qcli_iscsi` creates/maps/ACLs targets and LUNs correctly
(file-based, since the pool has no block-level free space); discovery and
login succeed against the QNAP from `pinode-01`; a real `overlay` mount
works on the resulting iSCSI-backed ext4 — reads the lower layer, writes
land in the upper layer.

**Not yet proven, first-draft only:**
- `files/iscsi-overlay-root` — the custom initramfs script that logs into
  *two* targets and builds the overlay before root pivot. No off-the-shelf
  pattern for this exists (the stock `open-iscsi` initramfs hook handles
  one target as a plain block-device root); this is genuinely new code.
- Whether `ROOTFS_MOUNTED=yes` is the correct signal for this specific
  `initramfs-tools` build (`0.148.3+rpt2`, an RPi Foundation fork) to skip
  its own `mountroot` step — inferred from general `initramfs-tools`
  convention, not confirmed against this exact version.
- `--removetargetinitiator` syntax in `provision_node_lun.yml`, used to
  strip the default allow-all initiator QNAP adds automatically — inferred
  from `--addtargetinitiator`'s own `--help` output, never actually run.
- The block-device-resolution-by-target logic in `iscsi-overlay-root`
  (walking `/sys/class/iscsi_session/*/targetname`) — reasoned from how
  Linux exposes iSCSI sessions in sysfs, not exercised against two
  simultaneous sessions on real hardware yet.

Phase 2 is exactly this: converting one real node and working through
whichever of the above turns out to be wrong, with the rollback path
above as the safety net.
