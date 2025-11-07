################################################################################
# FILE: roles/nfs_netboot/README.md
################################################################################
# NFS Netboot Role

Configures NFS server infrastructure for Raspberry Pi 5 netboot with per-node storage using golden image from SD card.

## Usage

### Day0: Initial Server Setup
Insert SD card with clean golden image, then run:
```bash
ansible-playbook day0-nfs-prep.yml --limit nfs_server
