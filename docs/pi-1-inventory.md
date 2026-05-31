# pi-1 (k8smaster) — Rebuild Inventory

**Hostname:** k8smaster  
**IP:** 192.168.2.10 (wlan0, DHCP — see note)  
**MAC (eth):** 88:a2:9e:2e:af:a0  **MAC (wlan):** 88:a2:9e:2e:af:a1  
**OS:** Debian GNU/Linux 13 (trixie)  
**Kernel:** 6.12.47+rpt-rpi-2712  
**Arch:** arm64 (Pi 5)  
**Audited:** 2026-05-31

---

## 1. NFS Server

### What it does
Serves three NFS exports to the backend VLAN (192.168.1.0/27):
- `/srv/nfs/rpios/latest` — read-write root filesystem for netboot workers (single OS image shared)
- `/srv/nfs/cluster` — per-node overlay directories (e.g. `pinode-2793f1/{etc,root,var,tmp,home}`)
- `/srv/nfs/syslog-store` — remote syslog storage for workers

### Key files
| File | Notes |
|------|-------|
| `/etc/exports` | Live config — see exact content below |
| `/etc/nfs.conf` | Non-default: `manage-gids=y` (mountd), `vers3=y`, `vers4.2=y` |
| `/srv/nfs/rpios/latest/` | Full Pi OS root tree (populated separately) |
| `/srv/nfs/cluster/pinode-2793f1/` | Per-node overlay dirs |

### /etc/exports (exact)
```
/srv/nfs 192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,fsid=0,crossmnt)
/srv/nfs/rpios/latest 192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,nohide)
/srv/nfs/cluster 192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,nohide)

# Direct exports for NFSv3
/srv/nfs/rpios/latest 192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,insecure)
/srv/nfs/cluster 192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,insecure)

# syslog export
/srv/nfs/syslog-store  192.168.1.0/27(rw,sync,no_subtree_check,no_root_squash,insecure)
```

Note: duplicate exports for `rpios/latest` and `cluster` (both `nohide` and `insecure`) — this is intentional to support both NFSv4 and NFSv3 mounts simultaneously.

### /etc/nfs.conf non-defaults
```ini
[mountd]
manage-gids=y

[nfsd]
vers3=y
vers4.2=y
```

### Ansible tasks needed
```yaml
- package: name=nfs-kernel-server state=present
- file: path={{ item }} state=directory mode=0755
  with_items: [/srv/nfs, /srv/nfs/rpios/latest, /srv/nfs/cluster, /srv/nfs/syslog-store]
- template: src=exports.j2 dest=/etc/exports  # already exists in roles/nfs_netboot
- lineinfile: path=/etc/nfs.conf ...          # manage-gids, vers3, vers4.2
- service: name=nfs-kernel-server enabled=yes state=started
- command: exportfs -ra
```

---

## 2. Netboot / PXE / TFTP

### Architecture
PXE/DHCP/TFTP is **not running on the host directly** — it runs as Kubernetes workloads in the `infra` namespace:

| Workload | Image | Role |
|----------|-------|------|
| `dhcpd` (Deployment, 0/1 — CrashLoopBackOff) | `ghcr.io/gorttman/dhcpd:latest` | ISC DHCP with PXE options for backend VLAN |
| `pxe-http` (Deployment, 2/2 Running) | `nginx:1.25-alpine` + `ghcr.io/gorttman/tftp:latest` | HTTP server + TFTP server for boot files |

The host has `tftp-hpa` installed as a client only (not the server daemon).

### DHCP config (from ConfigMap `infra/dhcpd-config`)
```
Subnet: 192.168.1.0/27
Range: 192.168.1.11–192.168.1.30
DNS: 192.168.2.1, 1.1.1.1
Domain: i3sec.com.au
next-server: 192.168.1.10 (DHCP opt 66)
bootfile: start4.elf (DHCP opt 67)

Static reservations:
  pinode-01  MAC=2c:cf:67:27:93:f1  IP=192.168.1.11
             bootfile=pinode-01/start4.elf
  valinor-m  MAC=00:08:9b:bb:ee:da  IP=192.168.1.30
```

### iPXE chain (from ConfigMap `infra/pxe-http-config`)
```ipxe
#!ipxe
dhcp
set base-url http://pxe.i3sec.com.au:8081/images
kernel ${base-url}/vmlinuz initrd=initrd.img root=/dev/nfs \
  nfsroot=nfs.i3sec.com.au:/nfs/rootfs rw ip=dhcp
initrd ${base-url}/initrd.img
boot
```

### Ansible tasks needed
- Apply k8s manifests for `infra/dhcpd` and `infra/pxe-http` (managed via ArgoCD — see §3)
- The `dhcpd` pod is currently in CrashLoopBackOff — **this is an open issue**
- TFTP boot files must be pre-populated in the volume mounted by `pxe-http`
- `end0` (the wired NIC at 88:a2:9e:2e:af:a0) needs a static IP of 192.168.1.10 on the backend VLAN for TFTP/next-server to work

### Warning — end0 has no IP
The wired interface `end0` currently has no IP address assigned. The backend VLAN (192.168.1.x) has no host-level route. This means the pi is reachable only over wlan0 (192.168.2.10). The NFS/TFTP next-server IP 192.168.1.10 must come from end0 — this is missing and needs to be configured.

---

## 3. k3s

### Version and role
- **Version:** v1.33.5+k3s1 (server/control-plane)
- **Runtime:** containerd 2.1.4-k3s1
- **Installed to:** `/usr/local/bin/k3s` (plus symlinks: `kubectl`, `crictl`)
- **Node name:** k8smaster
- **Roles:** control-plane, master
- **Internal IP:** 192.168.2.10 (wlan0)

### Nodes in cluster
| Node | Status | Role | IP | Version |
|------|--------|------|----|---------|
| k8smaster | Ready | control-plane,master | 192.168.2.10 | v1.33.5+k3s1 |
| pinode-01 | NotReady | worker | 192.168.2.11 | v1.33.6+k3s1 |

pinode-01 is NotReady — consistent with dhcpd CrashLoopBackOff / netboot issue.

### k3s service config
- Unit: `/etc/systemd/system/k3s.service`
- No `/etc/rancher/k3s/config.yaml` — k3s runs with defaults
- No `/etc/systemd/system/k3s.service.env`
- ExecStart: `/usr/local/bin/k3s server` (no extra flags)
- Kernel cmdline has `cgroup_memory=1 cgroup_enable=memory` (set in `/boot/firmware/cmdline.txt`)

### Namespaces and workloads running
| Namespace | Key workloads |
|-----------|--------------|
| kube-system | coredns, traefik, metrics-server, local-path-provisioner, sealed-secrets-controller |
| argocd | Full ArgoCD stack (application-controller, server, repo-server, dex, redis, notifications) |
| cert-manager | cert-manager + cainjector + webhook |
| infra | dhcpd (broken), pxe-http |
| ingress-nginx | ingress-nginx-controller |
| portainer | portainer |
| kubernetes-dashboard | dashboard + metrics-scraper |
| logging | syslog-ng, log-archiver (both stuck ContainerCreating/Terminating) |
| nfs-provisioner | nfs-client-provisioner (stuck ContainerCreating) |

### Node labels (no custom labels beyond k3s defaults)
Both nodes only carry built-in labels (`kubernetes.io/arch=arm64`, `kubernetes.io/os=linux`, etc.). No custom labels applied.

### Ansible tasks needed
```yaml
# k3s install (idempotent via official script)
- shell: curl -sfL https://get.k3s.io | sh -
  args: { creates: /usr/local/bin/k3s }
# Cgroups in cmdline.txt
- lineinfile:
    path: /boot/firmware/cmdline.txt
    regexp: '(^(?!.*cgroup_enable=memory).*)$'
    line: '\1 cgroup_memory=1 cgroup_enable=memory'
    backrefs: yes
# k3s kubeconfig is at /etc/rancher/k3s/k3s.yaml — back up before wiping
```

---

## 4. Cloudflare Tunnel

**Not found on this host.** No `cloudflared` binary, service, or config in `/etc/cloudflared` or `~/.cloudflared`. This may be running as a k8s workload (not yet checked) or not yet deployed.

Action: check `kubectl get all -A | grep cloudflare` to confirm.

---

## 5. Systemd Units

### Non-standard enabled units (i.e. not default Debian install)
| Unit | State | Notes |
|------|-------|-------|
| `k3s.service` | enabled, running | Kubernetes server |
| `docker.service` | enabled, running | Docker daemon (separate from containerd/k3s) |
| `containerd.service` | enabled, running | containerd (k3s dependency) |
| `nfs-server.service` | enabled, active(exited) | NFS kernel server |
| `nfs-blkmap.service` | enabled, running | pNFS block layout |
| `rpcbind.service` | enabled, running | Required for NFS |
| `fsidd.service` | enabled, running | NFS FSID daemon |

### Hand-modified units in /etc/systemd/system/
The following files are present but are stock package-installed (wpa_supplicant, bluetooth, avahi, ModemManager, NetworkManager-dispatcher, timesyncd, sshd):
- Only `k3s.service` is non-package (installed by k3s install script)

### /etc/systemd/timesyncd.conf (modified)
```ini
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=time.google.com time.cloudflare.com
```
(Default Debian uses `debian.pool.ntp.org` servers — this has been changed.)

### Ansible tasks needed
```yaml
- lineinfile:
    path: /etc/systemd/timesyncd.conf
    regexp: '^NTP='
    line: 'NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org'
- lineinfile:
    path: /etc/systemd/timesyncd.conf
    regexp: '^FallbackNTP='
    line: 'FallbackNTP=time.google.com time.cloudflare.com'
- service: name=systemd-timesyncd enabled=yes state=restarted
```

---

## 6. Packages

### apt sources
- Standard Debian trixie repos + Raspberry Pi archive keyring
- No non-standard PPAs or third-party apt sources detected
- No apt pinning (`/etc/apt/preferences.d/` not inspected — add to next audit)

### Manually installed packages (apt-mark showmanual) — notable ones
Beyond standard Debian system packages:

| Package | Purpose |
|---------|---------|
| `ansible` | Automation (this repo) |
| `docker.io` | Docker engine |
| `nfs-kernel-server` | NFS server |
| `nfs-common` | NFS client utils |
| `tftp-hpa` | TFTP client (NOT server daemon) |
| `k3s` | Installed via script, not apt |
| `git` | Source control |
| `curl` | Downloads |
| `python3-kubernetes` | k8s Python client |
| `python3-pip`, `python3-venv` | Python tooling |
| `htop`, `ncdu`, `vim`, `strace`, `tcpdump` | Admin tools |
| `rsync` | File sync |
| `build-essential`, `gdb` | Dev tools |
| `cifs-utils` | SMB mount support |
| `mkvtoolnix`, `p7zip-full`, `ntfs-3g` | Media/archive tools (likely personal) |

### Locally installed binaries (not via apt)
| Binary | Path | Notes |
|--------|------|-------|
| `k3s` | `/usr/local/bin/k3s` | Installed via `get.k3s.io` script |
| `kubectl` | `/usr/local/bin/kubectl` | Symlink to k3s |
| `crictl` | `/usr/local/bin/crictl` | k3s bundled |
| `kubeseal` | `/usr/local/bin/kubeseal` | Sealed Secrets CLI — **manually installed, version unknown** |
| `k3s-killall.sh` | `/usr/local/bin/k3s-killall.sh` | k3s install script artifact |
| `k3s-uninstall.sh` | `/usr/local/bin/k3s-uninstall.sh` | k3s install script artifact |
| `seal_secret.sh` | `/usr/local/bin/seal_secret.sh` | Custom GitOps helper script |

### Ansible tasks needed
```yaml
- package: name={{ item }} state=present
  with_items:
    - nfs-kernel-server
    - nfs-common
    - tftp-hpa        # client only
    - docker.io
    - git
    - curl
    - python3-kubernetes
    - python3-pip
    - python3-venv
    - htop
    - ncdu
    - vim
    - strace
    - tcpdump
    - rsync
    - cifs-utils
    - build-essential
    - ansible
# kubeseal — must be installed from GitHub releases for correct arch/version:
- get_url:
    url: https://github.com/bitnami-labs/sealed-secrets/releases/download/v{{ kubeseal_version }}/kubeseal-{{ kubeseal_version }}-linux-arm64.tar.gz
    dest: /tmp/kubeseal.tar.gz
# seal_secret.sh — copy from roles or this repo
- copy: src=seal_secret.sh dest=/usr/local/bin/seal_secret.sh mode=0755
```

---

## 7. Hand-edited /etc files

Files in `/etc` that are newer than `/etc/passwd` and not managed by dpkg/systemd wiring:

| File | What changed | Ansible task |
|------|-------------|--------------|
| `/etc/exports` | NFS exports (see §1) | `template: src=exports.j2` |
| `/etc/nfs.conf` | `manage-gids=y`, `vers3=y`, `vers4.2=y` | `lineinfile` or `blockinfile` |
| `/etc/systemd/timesyncd.conf` | NTP servers changed to pool.ntp.org + google/cloudflare fallback | `lineinfile` (see §5) |
| `/etc/hosts` | Added `127.0.1.1 k8smaster` | `lineinfile` |
| `/etc/resolv.conf` | `search i3sec.com.au`, `nameserver 192.168.2.1` | Managed by NetworkManager — set via NM connection profile |
| `/boot/firmware/cmdline.txt` | Added `cgroup_memory=1 cgroup_enable=memory cfg80211.ieee80211_regdom=AU` | `lineinfile` with backrefs |

### /etc/hosts (exact)
```
127.0.0.1   localhost
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
127.0.1.1   k8smaster
```

---

## 8. Network

### Interfaces
| Interface | Type | IP | Notes |
|-----------|------|----|-------|
| `end0` (enx88a29e2eafa0) | Wired | **None** | Should be 192.168.1.10 for backend VLAN |
| `wlan0` (wlx88a29e2eafa1) | WiFi | 192.168.2.10/24 (DHCP) | Primary management/cluster IP |
| `docker0` | Docker bridge | 172.17.0.1/16 | |
| `flannel.1` | k3s overlay | 10.42.0.0/32 | |
| `cni0` | k3s CNI bridge | 10.42.0.1/24 | |

### Default route
Via `wlan0` → 192.168.2.1 (WiFi gateway)

### DNS
`search i3sec.com.au`, `nameserver 192.168.2.1`

### NetworkManager
Only one connection profile found (meta file only, no `.nmconnection` content). WiFi credentials not visible. The wired `end0` has no NM profile — this is the gap that leaves the backend VLAN unreachable from the host.

### Ansible tasks needed
```yaml
# Static IP on end0 for backend VLAN
- nmcli:
    conn_name: backend-vlan
    ifname: end0
    type: ethernet
    ip4: 192.168.1.10/27
    state: present
```

---

## 9. Open Issues / Gaps

| Issue | Severity | Notes |
|-------|----------|-------|
| `end0` has no IP | High | Backend VLAN (192.168.1.x) unreachable from host; NFS exports to workers are broken at host level |
| `dhcpd` pod CrashLoopBackOff (213d) | High | Workers cannot PXE boot; root cause unknown — check pod logs |
| `pinode-01` NotReady | High | Worker node down — likely downstream of dhcpd/netboot failure |
| `nfs-client-provisioner` stuck ContainerCreating (134d) | Medium | Dynamic NFS PVC provisioning broken |
| `logging/syslog-ng` + `log-archiver` stuck Terminating/ContainerCreating (134d) | Medium | Log shipping broken |
| Cloudflare Tunnel not found | Low | May not be deployed yet or running as a k8s workload not yet inspected |
| No k3s `config.yaml` | Low | All k3s config is default — document intended flags before rebuild |
| WiFi as primary interface | Low | If WiFi drops, cluster loses management access; consider making eth static+primary |
| `kubeseal` version unknown | Low | Pin version in Ansible var before rebuild |
