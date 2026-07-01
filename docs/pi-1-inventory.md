# pi-1 (k8smaster) — Rebuild Inventory

**Hostname:** k8smaster  
**IP:** 192.168.2.10 (wlan0, DHCP — see note)  
**MAC (eth):** 88:a2:9e:2e:af:a0  **MAC (wlan):** 88:a2:9e:2e:af:a1  
**OS:** Debian GNU/Linux 13 (trixie)  
**Kernel:** 6.12.47+rpt-rpi-2712  
**Arch:** arm64 (Pi 5)  
**Audited:** 2026-05-31  
**Last updated:** 2026-06-03 (pinode-01 kubelet proxy + containerd fixes — see §13)

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
| `dhcpd` (Deployment, 1/1 Running) | `ghcr.io/gorttman/dhcpd:latest` | ISC DHCP with PXE options for backend VLAN |
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
- TFTP boot files must be pre-populated in the volume mounted by `pxe-http`
- `end0` must have static IP 192.168.1.10/27 (NM connection `backend-vlan`) — see §8

### Note — dhcpd interface binding
The `dhcpd` deployment uses `hostNetwork: true` and binds to `end0` (Pi 5 predictable interface name). The manifest in `day1-foundation/apps/dhcpd/dhcpd-deploy.yml` was previously hardcoded to `eth0` which caused 213 days of CrashLoopBackOff. Fixed 2026-05-31.

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
| Node | Status | Role | InternalIP | Version |
|------|--------|------|-----------|---------|
| k8smaster | Ready | control-plane,master | 192.168.2.10 (wlan0) | v1.33.5+k3s1 |
| pinode-01 | Ready | worker | 192.168.1.11 (eth0, wired) | v1.33.6+k3s1 |

Note: pinode-01's InternalIP is the wired management NIC (`192.168.1.11`), not wlan0 (`192.168.2.11`). WiFi AP isolation prevents direct Pi-to-Pi WiFi communication — both 192.168.2.x IPs are unreachable between nodes. The k3s tunnel WebSocket must traverse the wired network.

### k3s service config (k8smaster)
- Unit: `/etc/systemd/system/k3s.service`
- Config: `/etc/rancher/k3s/config.yaml` (see below)
- No `/etc/systemd/system/k3s.service.env`
- ExecStart: `/usr/local/bin/k3s server` (no extra flags — config via config.yaml)
- Kernel cmdline has `cgroup_memory=1 cgroup_enable=memory` (set in `/boot/firmware/cmdline.txt`)

### /etc/rancher/k3s/config.yaml (k8smaster, exact)
```yaml
tls-san:
  - 192.168.1.10
advertise-address: 192.168.1.10
```
Without `advertise-address`, k3s auto-detects the primary IP (wlan0 / 192.168.2.10) and broadcasts it to agents for the tunnel WebSocket. Workers can't reach that IP (WiFi AP isolation), so the tunnel never connects and `kubectl exec/logs` returns 502. Setting `advertise-address: 192.168.1.10` (management NIC) fixes this. `tls-san` adds the management NIC IP to the server TLS cert so agents can verify it.

### k3s agent config (pinode-01, in per-node etc overlay)
`/srv/nfs/cluster/pinode-2793f1/etc/rancher/k3s/config.yaml`:
```yaml
server: https://192.168.1.10:6443
token: <redacted>
node-ip: 192.168.1.11
```
`node-ip` pins the node's InternalIP to the wired NIC. Without it, k3s picks wlan0 (192.168.2.11) which k8smaster can't reach for kubelet proxy calls.

### Namespaces and workloads running
| Namespace | Key workloads |
|-----------|--------------|
| kube-system | coredns, traefik, metrics-server, local-path-provisioner, sealed-secrets-controller |
| argocd | Full ArgoCD stack (application-controller, server, repo-server, dex, redis, notifications) |
| cert-manager | cert-manager + cainjector + webhook |
| infra | dhcpd (healthy), pxe-http |
| ingress-nginx | ingress-nginx-controller |
| portainer | portainer |
| kubernetes-dashboard | dashboard + metrics-scraper |
| logging | syslog-ng (1/1 Running, pinned to k8smaster, TCP NodePort 30514 / UDP 30515, `externalTrafficPolicy: Local`), log-archiver CronJob (completing at 02:00 daily) |
| nfs-provisioner | nfs-client-provisioner |
| pihole | pihole (healthy) — DNS at 192.168.2.10:53 / 192.168.2.11:53, web UI via traefik ingress |

### Node labels (no custom labels beyond k3s defaults)
Both nodes only carry built-in labels (`kubernetes.io/arch=arm64`, `kubernetes.io/os=linux`, etc.). No custom labels applied.

### Ansible tasks needed
```yaml
# k3s install (idempotent via official script)
- shell: curl -sfL https://get.k3s.io | sh -
  args: { creates: /usr/local/bin/k3s }
# Write k3s server config
- copy:
    dest: /etc/rancher/k3s/config.yaml
    content: |
      tls-san:
        - 192.168.1.10
      advertise-address: 192.168.1.10
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
| `rsyslog.service` | enabled, running | Syslog daemon — forwards to syslog-ng NodePort |
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
| `rsyslog` | Syslog daemon — forwards to central syslog-ng |
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
| `kubeseal` | `/usr/local/bin/kubeseal` | Sealed Secrets CLI — installed via Ansible, pinned to v0.27.1 |
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
| `/etc/rsyslog.d/99-syslog-ng-forward.conf` | Forwards all logs to syslog-ng at `192.168.1.10:30514` (TCP) | Written directly by Ansible — see §12 |
| `/etc/rancher/k3s/config.yaml` | `tls-san: 192.168.1.10`, `advertise-address: 192.168.1.10` — forces k3s to use management NIC for tunnel | `copy` task — see §3 and §13 |

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
| `end0` (enx88a29e2eafa0) | Wired | 192.168.1.10/27 (static) | Backend VLAN — NM connection `backend-vlan` |
| `wlan0` (wlx88a29e2eafa1) | WiFi | 192.168.2.10/24 (DHCP) | Primary management/cluster IP |
| `docker0` | Docker bridge | 172.17.0.1/16 | |
| `flannel.1` | k3s overlay | 10.42.0.0/32 | |
| `cni0` | k3s CNI bridge | 10.42.0.1/24 | |

### Default route
Via `wlan0` → 192.168.2.1 (WiFi gateway)

### DNS
`search i3sec.com.au`, `nameserver 192.168.2.1`

### NetworkManager
Two connection profiles active: WiFi (unnamed, DHCP on wlan0) and `backend-vlan` (static 192.168.1.10/27 on end0, added 2026-05-31, `ipv4.never-default yes`).

### Ansible tasks needed
```yaml
# Static IP on end0 for backend VLAN
- nmcli:
    conn_name: backend-vlan
    ifname: end0
    type: ethernet
    ip4: 192.168.1.10/27
    gw4: ""
    state: present
```

---

## 9. Open Issues / Gaps

### Rebuild blockers (manual steps required after Ansible run)

| Issue | Severity | Manual fix |
|-------|----------|-----------|
| QNAP NAS `/syslog-archive` NFS export | **High** | SSH admin@192.168.1.30, add `syslog-archive` to all sections of `/etc/config/nfssetting`, run `/etc/init.d/nfs.sh restart`. Without this, log-archiver CronJob fails to mount its archive target. See §10 Fix 7 for exact commands. |
| WiFi credentials | **Closed** | Stored in `credentials/wifi/{ssid,psk}` (gitignored). `prep_prerequisites/network.yml` configures the NM connection automatically. Initial console access (keyboard/USB serial/ethernet) required on first boot only. |

### Non-blockers

| Issue | Severity | Notes |
|-------|----------|-------|
| Cloudflare Tunnel not found | Low | Not yet deployed or not yet inspected in k8s workloads |
| WiFi as primary interface | Low | If WiFi drops, cluster loses management access; `end0` is wired backup but only has 192.168.1.10 (backend VLAN, not routed to internet) |
| `kubeseal` / sealed-secrets-controller version match | Low | `kubeseal` is pinned to v0.27.1 — verify controller image matches before next rebuild: `kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'` |

---

## 10. Fixes Applied 2026-05-31

### Fix 1 — end0 static IP (backend VLAN)
**Problem:** `end0` had no IP, making 192.168.1.0/27 unreachable from the host.  
**Fix:** Created NM connection `backend-vlan` with static IP 192.168.1.10/27, `ipv4.never-default yes`.  
**Command:** `nmcli connection add type ethernet ifname end0 con-name backend-vlan ipv4.method manual ipv4.addresses 192.168.1.10/27 ipv4.never-default yes connection.autoconnect yes`  
**Ansible:** `nmcli` task — see §8.

### Fix 2 — dhcpd CrashLoopBackOff (213 days)
**Problem:** `day1-foundation/apps/dhcpd/dhcpd-deploy.yml` bound dhcpd to `eth0`. Pi 5 uses predictable interface naming (`end0`). With `hostNetwork: true` the container sees host interfaces directly — `eth0` doesn't exist, so dhcpd exited immediately.  
**Fix:** Changed `eth0` → `end0` in the deployment args. Committed to `day1-foundation` and ArgoCD synced.  
**Result:** dhcpd `1/1 Running`, listening on `LPF/end0/88:a2:9e:2e:af:a0/192.168.1.0/27`.

### Fix 3 — pinode-01 NotReady
**Cause:** Downstream of Fix 2 — worker had lost DHCP/netboot connectivity.  
**Result:** Came Ready automatically once dhcpd was serving. No manual intervention needed.

### Fix 4 — log-archiver CreateContainerConfigError
**Problem:** Secret `log-archiver-secret` did not exist. The manifest `log-archiver-secret.yml` created a secret named `nas-config` — name mismatch with what the CronJob referenced.  
**Fix:** Corrected secret name to `log-archiver-secret`, updated `NFS_EXPORT_PATH` from `/volume1/syslog-archive` to `/syslog-archive`, set `ARCHIVE_DAYS` to `3`.

### Fix 5 — log-archiver apk failure (wakeonlan not in Alpine)
**Problem:** `apk add wakeonlan` fails on Alpine — package doesn't exist. Because bash wasn't installed (the apk failed), the `#!/bin/bash` script returned "not found".  
**Fix:** Split apk installs — core packages (`bash nfs-utils iputils coreutils`) in one call, `etherwake` in a second call with `|| true`. Updated `wake_nas()` in the configmap to prefer `etherwake`.

### Fix 6 — log-archiver wrong NFS export path
**Problem:** `NFS_EXPORT_PATH=/srv/nas/logs` — path doesn't exist on the NAS.  
**Discovery:** `showmount -e 192.168.1.30` showed actual exports; correct path is `/syslog-archive`.  
**Fix:** Updated secret value to `/syslog-archive`.

### Fix 7 — QNAP NAS access denied for /syslog-archive
**Problem:** Even with the correct path, mount returned "access denied". The QNAP NFS config at `/etc/config/nfssetting` had no entry for `syslog-archive` — only `homes`, `nfsroot`, `Public`, `tftpboot` were enabled for NFS.  
**NAS details:** valinor-m, 192.168.1.30, QNAP, admin/admin SSH, QNAP kernel 3.4.6.  
**Fix:** Added `syslog-archive` to all sections of `/etc/config/nfssetting` (Access, AllowIP `*`, Permission `rw`, SquashOption `no_root_squash`, AnonUID/GID `65534`), then ran `/etc/init.d/nfs.sh restart`.  
**Result:** log-archiver CronJob now completes cleanly at 02:00 daily.

---

## 11. Fixes Applied 2026-06-01

### Fix 8 — pihole namespace missing (day2-services OutOfSync)
**Problem:** ArgoCD `day2-services` was OutOfSync with error "namespaces 'pihole' not found". The `pihole-namespace.yml` manifest exists but was never applied.  
**Fix:** Created the `pihole` namespace directly, then triggered ArgoCD resync.

### Fix 9 — pihole Application created in wrong namespace
**Problem:** `apps/kustomization.yml` had `namespace: pihole` at the top level. Kustomize applied this to all resources including `pihole-app.yml` (an ArgoCD Application), overriding its `namespace: argocd`. ArgoCD only watches its own namespace for Application resources, so pihole was silently never reconciled. A stale Application object sat in the `pihole` namespace for months.  
**Fix:** Removed `namespace: pihole` from `day2-services/apps/kustomization.yml`. Deleted the misplaced Application from the `pihole` namespace, triggered resync — pihole Application now created in `argocd` namespace correctly.  
**Repo:** `day2-services` commit `7c57a21`.

### Fix 10 — pihole scheduling failure (hostNetwork port conflict)
**Problem:** With `hostNetwork: true`, the scheduler treats all declared `containerPorts` as host ports. Ports 80 and 443 were declared, conflicting with traefik's svclb pods on both nodes — pihole could not be scheduled anywhere.  
**Fix:** Removed ports 80 and 443 from `containerPorts`. Pihole scheduled successfully on pinode-01.  
**Repo:** `day2-services` commit `c35363d`.

### Fix 11 — pihole liveness probe killing healthy container (hostNetwork vs traefik conflict)

**Problem:** Even after scheduling, probes returned 404. With `hostNetwork: true`, both pihole (lighttpd) and traefik's svclb nginx compete for port 80 on the host. The kubelet's probe hit traefik (which had no route for `/admin/`) rather than pihole, killing the container every 60s via the liveness probe.  
**Root cause verified:** `PIHOLE_WEB_PORT` is not a valid pihole env var — lighttpd ignores it. Additionally, Kubernetes auto-injects `PIHOLE_WEB_PORT=tcp://<clusterIP>:80` from the `pihole-web` service, overriding any configmap value.  
**Fix:** Removed `hostNetwork: true` entirely. Pihole runs in its own network namespace. DNS (port 53) exposed via `LoadBalancer` service at `192.168.2.53` (served by traefik svclb on both nodes). Web UI served on port 80 via the existing `pihole-web` ClusterIP service and traefik ingress at `pihole.pilab.local`.  
**Repo:** `day2-services` commit `aca07c9`.  
**Result:** pihole `1/1 Running`, `Synced / Healthy`, zero restarts. DNS at `192.168.2.10:53` / `192.168.2.11:53`.

---

## 12. Fixes Applied 2026-06-02

### Fix 12 — syslog-ng receiving no logs (rsyslog not installed, wrong TCP driver)

**Problem:** syslog-ng pod was running for 174 days with zero messages received. No node was configured to forward syslog, and rsyslog was not installed in the NFS rootfs.

**Root causes and fixes (in order):**

**12a — rsyslog not in NFS rootfs**  
The debootstrap-built rootfs had no syslog daemon. Chroot-installed rsyslog into the live rootfs at `/srv/nfs/rpios/latest/` directly (manual fix, not automated at the time). On k8smaster, installed directly via apt.  
**Correction (2026-07-01):** this fix was originally recorded as "baked into `roles/prep_rootfs/tasks/configure_rsyslog.yml` for future rebuilds," but that role built to an orphaned staging path never synced to the live `nfs_os_path` (`/srv/nfs/rpios/latest`) — see `docs/rebuild-gap-audit.md` item 4. That role has since been deleted as dead code. **Installing rsyslog into the real base rootfs is not currently automated anywhere** — `setup_rsyslog_overlay.yml` only writes per-node config, assuming rsyslog is already present on the golden SD card image. Tracked as a follow-up in `docs/rebuild-gap-audit.md`.

**12b — syslog-ng TCP driver mismatch**  
The `syslog(transport("tcp"))` source driver expects RFC 6587 octet-counted framing. rsyslog's `omfwd` sends plain LF-terminated TCP syslog (RFC 3164). syslog-ng was closing every connection immediately.  
**Fix:** Changed TCP source to `network(transport("tcp"))` in `syslog-server-configmap.yml`.  
**Repo:** `day1-foundation` commit `2b19d5b`.

**12c — syslog-ng pod rescheduled to pinode-01 (broken kubelet proxy)**  
After the ConfigMap update triggered a rollout, the pod landed on pinode-01 whose kubelet API (port 10250) is unreachable via the API server proxy — making `kubectl exec` return 502.  
**Fix:** Added `nodeSelector: kubernetes.io/hostname: k8smaster` to the Deployment.  
**Repo:** `day1-foundation` commit `8e62dc0`.

**12d — pinode-01 /etc is a per-node NFS overlay**  
pinode-01 mounts `cluster/pinode-2793f1/etc` over `/etc`, masking the base rootfs `/etc`. Writing `rsyslog.conf` and the forwarding config to the base rootfs had no effect.  
**Fix:** Copied `rsyslog.conf` from the base rootfs and wrote the forwarding config directly into `/srv/nfs/cluster/pinode-2793f1/etc/`. Also created `/var/spool/rsyslog` in the node's `/var` overlay (same masking issue).  
**Ongoing:** Handled automatically — `roles/nfs_netboot/tasks/setup_rsyslog_overlay.yml` (called by `add_node` via `--tags manage_nodes`) copies `rsyslog.conf` and the forwarding config into each new node's overlay and creates `var/spool/rsyslog`.

**12e — pinode-01 can only reach syslog-ng via management NIC**  
Workers PXE-boot via `end0` (192.168.1.x) and have no route to `192.168.2.10` (wlan0/cluster network). The forwarding target must be `192.168.1.10:30514`.  
**Fix:** Updated `syslog_server_ip` in `variables/common/set_environment.yml` to `192.168.1.10` and corrected the per-node overlay config.

**12f — kube-proxy SNAT collapsing all source IPs to 10.42.0.1**  
Without `externalTrafficPolicy: Local`, kube-proxy masquerades NodePort traffic to the local pod CIDR gateway — all nodes' logs landed in the same `10.42.0.1/` per-host directory.  
**Fix:** Set `externalTrafficPolicy: Local` on the `syslog-ng-external` NodePort service. Works correctly because syslog-ng is pinned to k8smaster (pod is always local to the NodePort).  
**Repo:** `day1-foundation` commit `0312660`.

**Result:** Both k8smaster (`10.42.0.1/`) and pinode-01 (`192.168.1.11/`) forwarding to syslog-ng. Logs written to `/srv/nfs/syslog-store/logging-syslog-storage-pvc-.../` (10Gi NFS PVC), split by source IP into per-host daily files plus `all.log`.

### syslog-ng architecture summary

| Item | Value |
|------|-------|
| Pod | `logging/syslog-ng`, pinned to k8smaster |
| TCP NodePort | 30514 (maps to container port 6514) |
| UDP NodePort | 30515 (maps to container port 5514) |
| `externalTrafficPolicy` | `Local` — source IPs preserved |
| Log storage | `/srv/nfs/syslog-store/logging-syslog-storage-pvc-36707232-51d6-4600-91cb-d9782b50331d/` |
| Per-host logs | `/var/log/remote/<source-IP>/<YYYY-MM-DD>.log` |
| Consolidated log | `/var/log/remote/all.log` |
| Forwarding target (workers) | `192.168.1.10:30514` (management NIC — only NIC reachable from PXE nodes) |
| rsyslog config in rootfs | Not currently automated — installed manually on the live rootfs; see 12a correction above and `docs/rebuild-gap-audit.md` item 4 |
| Per-node overlay | Handled by `setup_rsyslog_overlay.yml` (called from `add_node` via `--tags manage_nodes`) |

---

## 13. Fixes Applied 2026-06-03

### Fix 13 — pinode-01 `kubectl exec/logs` returning 502 (k3s tunnel broken for 187+ days)

**Symptom:** `kubectl exec` and `kubectl logs` to any pod on pinode-01 returned `502 Bad Gateway` proxied from `127.0.0.1:6443`. DaemonSet pods (`svclb-traefik`, `svclb-pihole-dns`) had been stuck in `ContainerCreating` for 187 days.

**Root causes and fixes (in order):**

**13a — k3s registered pinode-01 with wlan0 IP (192.168.2.11)**  
Without `node-ip` set, k3s agent auto-detected wlan0 as the primary interface. The API server then proxied kubelet calls to `192.168.2.11:10250`, which k8smaster cannot reach (WiFi AP isolation prevents direct Pi-to-Pi WiFi traffic on 192.168.2.x).  
**Fix:** Added `node-ip: 192.168.1.11` to pinode-01's k3s config at `/srv/nfs/cluster/pinode-2793f1/etc/rancher/k3s/config.yaml`. Node now registers with its wired management IP.  
**Now automated:** the entire per-node `config.yaml` (`server`, `token`, `node-ip`) is written by `roles/nfs_netboot/tasks/setup_k3s_agent_overlay.yml`, called from `add_node` during `--tags manage_nodes` — see `docs/rebuild-gap-audit.md` item 3. Previously nothing installed or joined the k3s agent on new nodes at all; this also closes that gap.

**13b — k3s tunnel WebSocket targeting 192.168.2.10:6443 (unreachable)**  
k3s agents maintain a persistent WebSocket tunnel to the server (`/v1-k3s/connect`) used for `exec/logs`. The tunnel URL comes from the server's advertised address. Without `advertise-address`, k3s detected wlan0 (192.168.2.10) as primary and broadcast that. pinode-01 cached `192.168.2.10:6443` in `/var/lib/rancher/k3s/agent/etc/k3s-agent-load-balancer.json` and reconnected to it continuously — but 192.168.2.10 is also unreachable from pinode-01 (same AP isolation issue).  
**Fix:** Created `/etc/rancher/k3s/config.yaml` on k8smaster with `advertise-address: 192.168.1.10` and `tls-san: 192.168.1.10`. Restarted k3s — it regenerated the server TLS cert with 192.168.1.10 as a SAN and began advertising the management NIC. The agent updated its load balancer JSON and the tunnel connected.  
**Now automated:** `roles/install_required_software/tasks/post_install.yml` writes both values on every rebuild (`backend_vlan_ip` var) — see `docs/rebuild-gap-audit.md` item 1.

**13c — Per-node /etc/resolv.conf overlay empty (no DNS on pinode-01)**  
`/etc/resolv.conf` is in the per-node NFS overlay (`cluster/pinode-2793f1/etc/`), which contained only a `# Generated by NetworkManager` comment — masking the base rootfs version that has `nameserver 192.168.2.1`. With no nameservers, containerd couldn't resolve Docker Hub to pull images.  
**Fix:** Wrote `nameserver 1.1.1.1` + `nameserver 8.8.8.8` to the per-node overlay resolv.conf. Note: pihole at `192.168.2.1` is unreachable from pinode-01 (same WiFi AP isolation), so upstream DNS is used directly.

**13d — Containerd image store empty (pause image never imported)**  
The containerd data directory lives in the per-node `/var` overlay (`cluster/pinode-2793f1/var/`). The k3s-agent had never successfully imported its bundled images — the images directory (`/var/lib/rancher/k3s/agent/images/`) was missing entirely. Without the pause image (`rancher/mirrored-pause:3.6`), containerd cannot create pod sandboxes, so every pod stays in `ContainerCreating`.  
**Fix:** Pulled the image directly: `k3s ctr images pull docker.io/rancher/mirrored-pause:3.6`. All stuck DaemonSet pods transitioned to Running immediately.  
**Ongoing:** New nodes will have the same empty containerd state on first boot. The pause image must be pre-pulled or pre-seeded. See §9.

**Result:** `kubectl exec/logs` to pinode-01 pods working. DaemonSet pods Running. pihole DNS at `192.168.2.11:53` restored.

### WiFi AP isolation — network topology note

The home WiFi AP has client isolation enabled. Neither node can reach the other's WiFi IP (`192.168.2.10` ↔ `192.168.2.11`). All inter-node traffic that requires direct reachability (k3s tunnel, NFS, syslog) must use the wired management network (`192.168.1.x`). The cluster overlay network (flannel `10.42.x.x`) works because it tunnels through the k3s WebSocket, which now correctly uses the wired network.

### Open item — pre-seed pause image for new nodes

When a new worker node is onboarded, containerd starts empty. k3s will try to pull `rancher/mirrored-pause:3.6` on first pod scheduling. If DNS isn't working yet (see Fix 13c) this fails and pods stay in `ContainerCreating`.  
**Workaround until automated:** after onboarding a new node, SSH in and run:
```bash
k3s ctr images pull docker.io/rancher/mirrored-pause:3.6
```
**Better fix:** pre-seed the image tarball into the node's `/var` overlay or bake it into the NFS base rootfs as a k3s images tarball in `/var/lib/rancher/k3s/agent/images/`.
