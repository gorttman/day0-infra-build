################################################################################
# FILE: roles/nfs_netboot/README.md
################################################################################
# NFS Netboot Role

> **DEPRECATED 2026-09-03 - the netboot boot path has been dropped.**
> Nodes boot from local storage; the current pipeline is `iscsi_netboot`
> (golden squashfs) heading to local NVMe. The `dhcpd` and `pxe-http`
> Applications that made netboot work are both disabled in
> `day1-foundation/apps/kustomization.yml`, and nothing serves TFTP or
> DHCP any more (verified 2026-09-03: nothing listening on 67/udp or
> 69/udp). Code kept deliberately, not deleted - it is the only
> procedure that exists for standing a netboot node back up.
>
> **DO NOT delete `/srv/nfs/rpios/latest` as part of any netboot
> cleanup.** Despite living under a netboot-shaped path, that tree is
> still the live source filesystem for the CURRENT golden image:
> `roles/iscsi_netboot/tasks/build_golden_image.yml` runs
> `mksquashfs {{ nfs_os_path }}`, and `nfs_os_path` resolves to
> `/srv/nfs/rpios/latest` (`variables/play/day0_iscsi_prep.yml`).
> It also cannot be rebuilt from code alone - `import_from_sd_card.yml`
> below requires a physical SD card already carrying a prepared golden
> image, which is a manual hardware step, not an automated one.
>
> `/srv/nfs/rpios/latest-2024-11-stale` is a different matter: that is
> the pre-2026-08-27 image, superseded by the golden-image rebuild and
> referenced by nothing.


Configures NFS server infrastructure for Raspberry Pi 5 netboot with per-node storage using golden image from SD card.

## Usage

### Day0: Initial Server Setup
Insert SD card with clean golden image, then run:
```bash
ansible-playbook day0-nfs-prep.yml --limit nfs_server
