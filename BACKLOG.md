# day0-infra-build Backlog

Tracks outstanding work for the pi-lab infrastructure build-out.
Items move left to right: **Icebox → Todo → In Progress → Done**

---

## In Progress

_Nothing currently in flight._

---

## Todo

### Bug (URGENT): worker nodes go offline after ~24 hours and cannot be SSH'd into
After approximately 24 hours, PXE-booted worker nodes (pinode-01 etc.) become unreachable — no SSH, node may drop out of `kubectl get nodes`. Master is unaffected.
- **Suspected causes:** DHCP lease expiry (default ISC DHCP lease is 24h — node may lose its IP or fail to renew), NFS root mount going stale/timing out (NFS hard mount with `timeo=600` could lock up on reconnect), or SSH host key rotation on the shared NFS rootfs conflicting with per-node overlay
- **To investigate:** check DHCP lease time in dhcpd ConfigMap; check NFS mount options (`hard` vs `soft`, `intr`); check if node is still pingable when SSH fails; check k3s node status at the 24h mark; check `/var/log/remote/192.168.1.11/` syslog for what happens just before the node drops
- **Note:** now that syslog forwarding is working, the logs at the moment of failure should be visible in syslog-ng — deliberately trigger by waiting or check tomorrow morning

---

## Icebox

### Feature: 1Password integration for credential population
Currently `credentials/git-pat/token.txt` and `credentials/wifi/{ssid,psk}` are populated manually. A `populate_credentials` role using `community.general.onepassword` lookup + `op` CLI would fetch secrets from 1Password on first run (or on `--tags rotate_git_token` / `--tags change_wifi`). Files are the working copy; 1Password is source of truth. Needs `op` CLI installed on the Pi and `eval $(op signin)` or `OP_SERVICE_ACCOUNT_TOKEN` set before running.

### Feature: QNAP NAS syslog-archive NFS export automation
Currently a manual SSH step into valinor-m (192.168.1.30) to add `syslog-archive` to all sections of `/etc/config/nfssetting` and restart NFS. Could be automated via an Ansible task using `raw` or `ssh` against the QNAP. Low urgency — log-archiver CronJob fails silently until this is done and disk space on the Pi is not a concern at current OS footprint.
- **Details:** `docs/rebuild-runbook.md` §5, `docs/pi-1-inventory.md` §9 Fix 7

### Feature: pin k3s version
Currently `get.k3s.io` installs latest stable. Intentional for now. Revisit if a bad release causes a broken rebuild — at that point add `INSTALL_K3S_VERSION` to the install task.
- **File:** `roles/install_required_software/tasks/install_required_software_curl.yml`

### Feature: Cloudflare Tunnel
Not currently deployed. Not found on host or in k8s workloads. No action needed until a use case is identified.

### Feature: container log collection + metrics (observability stack)
Current logging covers host OS only (rsyslog → syslog-ng). Container stdout/stderr and cluster metrics are not collected.
- **Logs:** Fluent Bit DaemonSet reading `/var/log/containers/` → syslog-ng or Loki
- **Metrics:** Prometheus + node-exporter DaemonSet + kube-state-metrics + Grafana
- **Note:** sidecar approach was considered and rejected in favour of DaemonSet — covers all pods automatically without touching app manifests. Lightweight stack preferred given Pi hardware.

### Chore: pre-seed pause image for new worker nodes
On first boot, containerd is empty. k3s tries to pull `rancher/mirrored-pause:3.6` from Docker Hub when scheduling the first pod. If DNS isn't working yet the pull fails and pods stay in `ContainerCreating`.
- **Workaround:** SSH to new node and run `k3s ctr images pull docker.io/rancher/mirrored-pause:3.6`
- **Proper fix:** bake a k3s images tarball into the NFS base rootfs at `/var/lib/rancher/k3s/agent/images/` during `roles/nfs_netboot/tasks/configure_nfs_root_common.yml` (base rootfs chroot setup), or pre-pull in `add_node` via SSH after onboarding
- **Details:** `docs/pi-1-inventory.md` §13

### Chore: verify kubeseal v0.27.1 matches sealed-secrets-controller version
Before next rebuild, confirm `kubeseal` CLI version matches the `sealed-secrets-controller` image version running in `kube-system`. A mismatch causes `kubeseal` to produce secrets the controller can't decrypt.
- **Check:** `kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'`
