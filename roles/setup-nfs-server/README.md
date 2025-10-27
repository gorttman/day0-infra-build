# Role: setup-nfs-server

## Purpose

This role configures an NFS kernel server to export root filesystems and per-node state directories for diskless Raspberry Pi 5 cluster nodes that boot via network (PXE/HTTP) and mount their root filesystem via NFS.

## What This Role Does

This role represents the **delta** between what was initially in the repository and what actually works for NFS-based diskless boot. The original repository had roles to:

1. Create the root filesystem (`prep-rootfs`)
2. Build kernel and initramfs (`prep-kernel`)
3. Copy files to `/srv/nfs/base` (`publish-nfs-os`)

But it was **missing** the actual NFS server configuration that makes those files accessible to the booting nodes. This role fills that gap.

## Tasks Performed

1. **Install NFS Server Packages**
   - Installs `nfs-kernel-server` and `nfs-common`
   - Updates APT cache

2. **Configure NFS Exports**
   - Creates `/etc/exports` with proper export entries
   - Exports `/srv/nfs/base` as the shared root filesystem (read-write for all nodes)
   - Exports `/srv/nfs/nodes` as the parent directory for per-node state
   - Reloads exports when configuration changes

3. **Create Per-Node Directories**
   - Creates directory structure for each node:
     - `/srv/nfs/nodes/<hostname>/state` - Per-node persistent state (machine-id, etc.)
     - `/srv/nfs/nodes/<hostname>/k3s` - Per-node k3s data directory
   - Configurable list of node hostnames

4. **Manage NFS Services**
   - Enables and starts `nfs-kernel-server`
   - Enables and starts `rpcbind`

## Variables

### Required Variables (from playbook vars)

- `NFS_EXPORT_PATH` - Base path for NFS exports (default: `/srv/nfs`)
- `NFS_SERVER_IP` - IP address of the NFS server (used in client mounts)

### Role Defaults (can be overridden)

```yaml
# NFS export options for base rootfs
nfs_base_export_options: "rw,sync,no_subtree_check,no_root_squash"

# NFS export options for per-node directories
nfs_node_export_options: "rw,sync,no_subtree_check,no_root_squash"

# Network to allow NFS access from
nfs_allowed_network: "192.168.1.0/24"

# List of node hostnames to create directories for
nfs_node_hostnames:
  - pinode01
  - pinode02
  - pinode03
```

## Integration with Other Roles

This role works in conjunction with:

1. **prep-rootfs** - Creates the actual root filesystem that gets exported
2. **publish-nfs-os** - Copies the rootfs to the NFS export directory
3. **prep-kernel** - Creates boot files and iPXE script with nfsroot parameters

The systemd mount units created by `prep-rootfs` in `install_node_overrides.yml` use the hostname variable `%H` to mount the correct per-node directories:

```ini
[Mount]
What=192.168.1.10:/srv/nfs/nodes/%H/state
Where=/state
Type=nfs
```

## What Didn't Work (Excluded)

As per the implementation requirements:

- **initrd modifications** - Not used, as the standard Debian initrd works fine
- **overlay filesystems** - Not used, bind mounts via systemd mount units work better
- **OverlayFS approach** - Replaced with direct NFS mounts + per-node writable directories

## What Actually Works

The working solution uses:

1. **NFS server exports** (this role) - Provides the shared rootfs
2. **Systemd mount units** (in prep-rootfs) - Bind mount per-node state using NFS
3. **Direct file copy** (publish-nfs-os) - Simple rsync to NFS export path
4. **Kernel cmdline NFS boot** (prep-kernel) - `nfsroot=` parameter in iPXE script

## Usage Example

```yaml
- name: Setup NFS server for diskless boot
  hosts: k8smaster
  become: true
  vars:
    nfs_node_hostnames:
      - rpi5-node01
      - rpi5-node02
      - rpi5-node03
      - rpi5-node04
  roles:
    - setup-nfs-server
```

## Directory Structure Created

```
/srv/nfs/
├── base/                      # Shared root filesystem (exported read-write)
│   ├── bin/
│   ├── boot/
│   ├── etc/
│   └── ...
└── nodes/                     # Per-node directories (exported read-write)
    ├── pinode01/
    │   ├── state/            # Per-node state (machine-id, etc.)
    │   └── k3s/              # Per-node k3s data
    ├── pinode02/
    │   ├── state/
    │   └── k3s/
    └── pinode03/
        ├── state/
        └── k3s/
```

## Generated /etc/exports

```
/srv/nfs/base 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
/srv/nfs/nodes 192.168.1.0/24(rw,sync,no_subtree_check,no_root_squash)
```

## Handlers

- `Reload NFS exports` - Runs `exportfs -ra` when /etc/exports changes
- `Restart NFS server` - Restarts nfs-kernel-server service

## Dependencies

None - this is a standalone role, but should be run before `publish-nfs-os` in the playbook.

## Author

Generated to capture the working NFS server configuration delta that was missing from the initial repository implementation.
