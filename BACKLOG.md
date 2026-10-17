# day0-infra-build Backlog

Tracks outstanding work for the pi-lab infrastructure build-out.
Items move left to right: **Icebox → Todo → In Progress → Done**

---

## In Progress

_Nothing currently in flight._

---

## Todo

### Move cloudflare-tf out of ArgoCD into a plan-first Ansible play (added 2026-10-17)
`day1-foundation/apps/cloudflare-tf` runs `terraform plan` then `apply` in one ArgoCD Sync-hook Job, with auto-sync on. Any push that touches that app applies to live Cloudflare (DNS, tunnel, WAF, mTLS) with no review step. Confirmed 2026-10-17: a comment-only `email.tf` push re-ran the apply; it succeeded and DNS was unchanged, but nothing in the process would have stopped a harmful change.
- **Target:** same shape as `unifi-tf-apply.yml`: plan by default, apply only with an explicit `-e ..._do_apply=true`, and refuse any destroy.
- **Keep:** the Postgres state backend, the sealed secrets, and the mTLS runbooks in the app README.
- **Order:** build the play, run a plan and confirm it reports no changes, then remove the ArgoCD app (two steps: comment out, then clean up; see the ArgoCD app-removal note).
- **Until then:** treat any push under `day1-foundation/apps/cloudflare-tf/` as a live Cloudflare apply.

### Bug (URGENT): worker nodes go offline after ~24 hours and cannot be SSH'd into
After approximately 24 hours, PXE-booted worker nodes (pinode-01 etc.) become unreachable — no SSH, node may drop out of `kubectl get nodes`. Master is unaffected.
- **Suspected causes:** DHCP lease expiry (default ISC DHCP lease is 24h — node may lose its IP or fail to renew), NFS root mount going stale/timing out (NFS hard mount with `timeo=600` could lock up on reconnect), or SSH host key rotation on the shared NFS rootfs conflicting with per-node overlay
- **To investigate:** check DHCP lease time in dhcpd ConfigMap; check NFS mount options (`hard` vs `soft`, `intr`); check if node is still pingable when SSH fails; check k3s node status at the 24h mark; check `/var/log/remote/192.168.1.11/` syslog for what happens just before the node drops
- **Note:** now that syslog forwarding is working, the logs at the moment of failure should be visible in syslog-ng — deliberately trigger by waiting or check tomorrow morning

---

## Icebox

### Feature: 1Password integration for credential population
Currently `credentials/git-pat/token.txt` and `credentials/wifi/{ssid,psk}` are populated manually. A `populate_credentials` role using `community.general.onepassword` lookup + `op` CLI would fetch secrets from 1Password on first run (or on `--tags rotate_git_token` / `--tags change_wifi`). Files are the working copy; 1Password is source of truth. Needs `op` CLI installed on the Pi and `eval $(op signin)` or `OP_SERVICE_ACCOUNT_TOKEN` set before running.

### Feature: QNAP NAS syslog-archive NFS export automation - RETIRED 2026-10-18
The old syslog-ng server and log-archiver were removed; the share is no longer needed or managed.

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

### Chore: pre-seed pause image for new worker nodes — CODE WRITTEN, NOT YET WORKING 2026-08-22
`roles/nfs_netboot/tasks/preseed_pause_image.yml` (wired into
`configure_nfs_root_common.yml`, so it covers both the NFS-root and
iSCSI-root golden images - both squashfs the same `nfs_os_path`)
attempts to export the pause image from k8smaster's own containerd
into the base rootfs, matching the proper-fix approach below. Confirmed
live it doesn't currently work: `k3s ctr images export` fails on a
missing content digest, reproducibly, even right after a fresh pull
reports everything complete - produced a 7KB file for an image that's
really 247KB. Full detail and what to try next in that task file's own
comment. Left wired in (idempotent, `creates:` guarded) since it's
harmless when it fails to produce output - just doesn't yet fix the
gap it's meant to.
- **Workaround still applies:** SSH to new node and run `k3s ctr images pull docker.io/rancher/mirrored-pause:3.6`
- **Details:** `docs/pi-1-inventory.md` §13

### Chore: verify kubeseal v0.27.1 matches sealed-secrets-controller version
Before next rebuild, confirm `kubeseal` CLI version matches the `sealed-secrets-controller` image version running in `kube-system`. A mismatch causes `kubeseal` to produce secrets the controller can't decrypt.
- **Check:** `kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'`
