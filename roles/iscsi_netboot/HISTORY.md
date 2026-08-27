# iscsi_netboot: build history, mistakes, and fixes

Same convention as `unifi_tf_apply/HISTORY.md` and `qnap_snapshot/HISTORY.md`
— if something looks weird in the code, the answer is probably in here.

## 1. Golden image rebuilt from scratch on a fresh RPi OS release (2026-08-27)

`/srv/nfs/rpios/latest` (`nfs_os_path`) was found to be dated 2024-11-02 -
built before this role existed at all (`build_golden_image.yml` was added
2026-08-17), and nearly two years stale. Decision: stop trying to drag an
old tree forward with `apt upgrade`, start fresh from the current official
release instead.

No physical SD card was available or needed. `nfs_netboot/tasks/
import_from_sd_card.yml` is the only documented import path and genuinely
requires a physical card in a reader - not remotely doable. Replicated its
exact effect instead: downloaded `2026-06-18-raspios-trixie-arm64-lite.img.xz`
from `downloads.raspberrypi.org` (sha256-verified against the published
checksum), `losetup -Pf` to get partitioned loop devices, mounted both
partitions read-only, `rsync -a` with the same excludes the import task
uses (`/dev,/proc,/sys,/tmp,/run,/mnt,/media,/lost+found`) into
`nfs_os_path`. Old tree moved aside to `latest-2024-11-stale`, not
deleted - nothing here needs it, but no reason to throw it away either.

Then ran the real pipeline (`ansible-playbook day0-infra-build.yml
--tags os_upgrade --limit k8smaster`) to lay the cluster's actual
customizations on top of the fresh base, rather than hand-patching it -
this is the same entrypoint that would run for any normal kernel/package
update, so the fresh tree ends up in exactly the state a normal upgrade
run would produce.

`--limit k8smaster` was deliberate: the play's `hosts: all` would
otherwise also run against `qnap` over SSH for tasks that assume a
Debian/apt chroot - the QNAP is BusyBox and has none of that, no reason
to let it try.

## 2. Pinned kernel version had aged out of the live apt repo (2026-08-27)

`install_iscsi_initiator.yml`'s kernel-install task pins an exact version
(`linux-image-rpi-2712=1:6.12.47-1+rpt1` etc.) - by the time of this
rebuild, `archive.raspberrypi.com`'s Packages index had moved on to
`6.18.34` as candidate, and the old exact version string was no longer
resolvable via `apt-get install pkg=version` at all, regardless of
whether it happened to already be the installed version. Real error:
`Version '1:6.12.47-1+rpt1' for 'linux-image-rpi-2712' was not found`.

Fix: `k8smaster` itself already runs this exact pinned kernel (`dpkg -l`
confirmed `1:6.12.47-1+rpt1` installed). Installed `dpkg-repack`,
reconstructed real installable `.deb`s from k8smaster's own currently-
running packages (the two tiny meta-packages `linux-image-rpi-2712`/
`-v8`, the real `linux-image-6.12.47+rpt-rpi-2712`/`-v8` packages
containing the actual kernel+modules, and `raspi-firmware`), copied them
into the chroot, `dpkg -i` directly - no internet dependency for the
exact pinned build at all.

Re-running the *exact same* `apt-get install pkg=version` command
afterward, once the packages were already installed at that version,
succeeded cleanly (apt treats an already-satisfied exact-version request
as a no-op without needing a live candidate lookup) - so this doesn't
need a permanent code change, just recovery if it recurs on some future
already-pruned pin.

## 3. Newer stock kernel silently won the "which kernel boots" race (2026-08-27)

The fresh 2026-06-18 base image ships `6.18.34` by default. Installing
the pinned `6.12.47` packages *alongside* it (rather than replacing) left
both present - and `raspi-firmware`'s postinst hook auto-selects the
*newest* installed kernel when publishing `/boot/firmware/kernel_2712.img`
/`kernel8.img`, silently republishing the wrong, unpinned kernel even
though the correct one was also installed. This is exactly the kind of
regression the pin exists to prevent (see this role's WiFi-bug comments)
- caught before it went anywhere near a real boot.

Fix: `apt-get purge` the `6.18.34` packages entirely so there's no
ambiguity for the hook to resolve, then force-regenerate: `update-
initramfs -c -k 6.12.47+rpt-rpi-2712` (and `-v8`), then directly invoke
`/etc/kernel/postinst.d/z50-raspi-firmware <version> <vmlinuz-path>` with
`DEB_MAINT_PARAMS=configure` set, to republish `boot/firmware/*` against
the correct kernel explicitly.

## 4. `--start-at-task` doesn't work across `include_tasks` (2026-08-27)

After fixing #2 mid-run, tried to resume the play from the next task
rather than re-run everything, via `--start-at-task "Hold the pinned
kernel packages..."`. Ansible refused: `No matching task ... Note:
--start-at-task can only follow static includes`. This role uses
`include_tasks` (dynamic) throughout, not `import_tasks` (static) - this
flag is a dead end here, don't try it again.

What actually worked: just re-run the full play
(`--tags os_upgrade --limit k8smaster`, no `--start-at-task`). Once the
real blocker is fixed, already-satisfied earlier tasks report `ok` and
move on quickly - it's not the wasteful full-rebuild it sounds like.

## 5. iSCSI login task isn't idempotent against an already-active session (2026-08-27)

Re-running the play while the golden target was still logged in from a
prior attempt failed at the login task: `iscsiadm: default: 1 session
requested, but 1 already present` (rc=15). The task has no `failed_when`
tolerance for this case.

Fix: log out cleanly before retrying -
`iscsiadm -m node --targetname iqn.2004-04.com.qnap:ts-669pro:iscsi.goldenimg.bbeed9
--portal 192.168.1.30 --logout`, confirm `iscsiadm -m session` reports
none active, then re-run.

## 6. Device-appearance wait timeout is too short on this hardware, reproducibly (2026-08-27)

`provision_golden_lun.yml`'s "Wait for the iSCSI block device to appear"
task loops 10 times at 1s intervals (10s total) after login, then fails.
Hit this **three times in a row**, every single retry, with the device
confirmed present and correctly mapped (verified via `udevadm info -q
property -n /dev/sda`, `ID_PATH` matching the exact target IQN) within
a second or two of the window closing. Not a one-off fluke - this
consistently takes longer than 10s on this hardware/network right now.

Didn't patch the timeout in this pass - touching a shared, tested role
deserves a deliberate change with its own thought, not a rushed one
while mid-recovery. Instead finished the remaining two tasks in the file
by hand once, after confirming the device: `dd if=/srv/nfs/iscsi-golden-image/
current.squashfs of=/dev/sda bs=4M conv=fsync`, then logged out.

**If this keeps happening on future rebuilds, the actual fix is raising
the loop count/interval in `provision_golden_lun.yml`, not repeating
this manual workaround again.**

## Result

`/srv/nfs/rpios/latest`: fresh Debian 13.5 Trixie
(`2026-06-18-raspios-trixie-arm64-lite`, sha256-verified), kernel pinned
and held at `6.12.47-1+rpt1` (`dpkg -l` shows `hi` status on both
`linux-image-6.12.47+rpt-rpi-2712` and `-v8`), all of this role's other
customizations applied via the real pipeline (dropbear rescue-shell SSH
key auth, NetworkManager resolv.conf fix, overlay/single-session iSCSI
hooks, netconsole diagnostics). Squashfs rebuilt and republished to the
golden LUN (`current.squashfs` -> `rpios-20260827T200609.squashfs`,
679,956,480 bytes, matches the `dd` write exactly). No mounts, loop
devices, or iSCSI sessions left dangling.

Not yet done: writing this tree onto pinode-01's NVMe once the hardware
is physically installed - see project memory `wired-migration-plan` for
the full sequence after that.
