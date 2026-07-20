# k8smaster Rebuild Runbook

Full rebuild sequence for pi-1 (k8smaster) from bare metal to a running cluster.
After the Ansible run, ArgoCD pulls all k8s workloads from git automatically.

**Estimated time:** ~30–45 minutes end-to-end.

---

## Prerequisites

- Raspberry Pi 5 with fresh Debian trixie SD card
- A second SD card with Raspberry Pi OS (for NFS rootfs import — inserted into Pi during step 4)
- SSH access to the Pi from your Ansible control machine
- This repo cloned locally: `git clone git@github.com:gorttman/day0-infra-build.git`

---

## Step 1 — Flash the OS and get initial console access

Flash Debian trixie (or Raspberry Pi OS Lite 64-bit) to the primary SD card.

Boot the Pi. Initial network access before Ansible runs — use whichever is available:
- **Direct console** (keyboard + monitor): simplest, no network needed
- **USB serial** (`/dev/ttyUSB0`, 115200 baud)
- **Ethernet** (`end0`): plug into a machine on the 192.168.1.0/27 network; end0 gets 192.168.1.10 once Ansible runs, but DHCP may give it a temporary address before that

WiFi does **not** need to be pre-configured on the SD card. Ansible configures it in step 3 using the credentials you provide in step 2.

Set the hostname before running Ansible:
```bash
hostnamectl set-hostname k8smaster
echo "127.0.1.1 k8smaster" >> /etc/hosts
```

---

## Step 2 — Copy credentials onto the Pi

Ansible needs two credential files. Both are gitignored and never committed.

**GitHub PAT** (needs `repo` scope for all repos in `day0_bootstrap.yml`):
```bash
mkdir -p credentials/git-pat
echo "YOUR_GITHUB_PAT" > credentials/git-pat/token.txt
```

**WiFi credentials** (plain text SSID and passphrase):
```bash
mkdir -p credentials/wifi
echo "YOUR_SSID"       > credentials/wifi/ssid
echo "YOUR_PASSPHRASE" > credentials/wifi/psk
```

**On a rebuild, pull the `credentials/` directory from the QNAP backup, not from anywhere on this host** — `/mnt/backup/k8smaster-credentials` on `qnap.i3sec.com.au` (`/backup` export), synced nightly by a root cron job the `qnap_client` role installs (`ansible.builtin.cron`, see `roles/qnap_client/tasks/main.yml`). This is a real disaster-recovery path precisely because it lives off this host's disk — until 2026-07-21 this section wrongly assumed "your secure backup" already existed; it didn't, `credentials/` had never left this one Pi. From another machine on the LAN:
```bash
mkdir -p credentials
sudo mount -t nfs -o ro qnap.i3sec.com.au:/backup /mnt/qnap-backup-ro
cp -r /mnt/qnap-backup-ro/k8smaster-credentials/. credentials/
sudo umount /mnt/qnap-backup-ro
```
Ansible reads from these files and configures both ArgoCD repo access and the WiFi NM connection.

If `credentials/sealed-secrets-key-*.yaml` is also present, Ansible restores the newest one into `kube-system` before ArgoCD deploys the sealed-secrets controller, so existing SealedSecrets in `day1-foundation`/`day2-services` stay decryptable — see `restore_sealed_secrets_key.yml`'s staleness check, which fails loudly rather than silently restoring a key that's missing the current rotation. These files are produced by the in-cluster `sealed-secrets-backup` CronJob (`day0-bootstrap/apps/sealed-secrets/sealed-secrets-cron.yml`), not `scripts/backup_sealed_secrets.sh` — that script was deliberately retired; don't reinstate it. No action needed beyond copying the whole `credentials/` directory across.

---

## Step 3 — Run the Day-0 bootstrap

From your Ansible control machine (or directly on the Pi):

```bash
ansible-playbook day0-infra-build.yml \
  --tags install_day0 \
  -u gorttman \
  --ask-become-pass
```

This runs in order:
1. `prep_prerequisites` — cgroups in cmdline.txt, /etc/hosts, backend-vlan NM connection (end0 → 192.168.1.10/27), NTP servers
2. `install_required_software` — apt packages, k3s, kubeseal v0.27.1
3. `apply_bootstrap` — installs ArgoCD v3.2.0, registers git repos, applies bootstrap Application
4. `install_helper_scripts` — copies seal_secret.sh to /usr/local/bin
5. `credentials_out` — prints ArgoCD URL and initial admin password

**If cgroups weren't already set**, the Pi will reboot mid-run. Re-run the playbook after it comes back up — it is idempotent.

---

## Step 4 — Set up NFS for worker netboot

Insert the Raspberry Pi OS SD card into the Pi's second SD slot, then:

```bash
ansible-playbook day0-infra-build.yml \
  --tags manage_nfs \
  -u gorttman \
  --ask-become-pass
```

This:
- Creates `/srv/nfs/{rpios/latest,cluster,syslog-store}`
- Configures `/etc/exports` and `/etc/nfs.conf` (NFSv3 + NFSv4.2, manage-gids)
- Copies the Pi OS golden image from the SD card into `/srv/nfs/rpios/latest`
- Sets up TFTP directory structure for netboot
- Installs rsyslog into the NFS rootfs (via chroot) and writes `/etc/rsyslog.d/99-syslog-ng-forward.conf` pointing at `192.168.1.10:30514`
- Installs the k3s agent binary + `k3s-agent.service` into the NFS rootfs (via chroot, skip-enable/skip-start — no join token known yet at this point)

> **Note — per-node /etc overlay:** Each worker's `/etc` is a separate NFS overlay from `cluster/<node>/etc/`, masking the base rootfs. The `add_node` task handles this automatically for both rsyslog (`roles/nfs_netboot/tasks/setup_rsyslog_overlay.yml` — copies `rsyslog.conf` and the forwarding config into the node's overlay, creates `var/spool/rsyslog`) and the k3s agent join (`roles/nfs_netboot/tasks/setup_k3s_agent_overlay.yml` — writes `/etc/rancher/k3s/config.yaml` with the server URL, join token, and `node-ip`, copies in the `k3s-agent.service` unit, and enables it). No manual steps needed for nodes onboarded via `--tags manage_nodes`.

---

## Step 5 — Manual: QNAP NAS export

The log-archiver CronJob mounts `/syslog-archive` from valinor-m (192.168.1.30). This is not automated.

```bash
ssh admin@192.168.1.30   # password: admin
```

Edit `/etc/config/nfssetting` — add `syslog-archive` to all six sections:

```ini
[Access]
/share/CACHEDEV1_DATA/syslog-archive = TRUE

[AllowIP]
/share/CACHEDEV1_DATA/syslog-archive = *

[Permission]
/share/CACHEDEV1_DATA/syslog-archive = rw

[SquashOption]
/share/CACHEDEV1_DATA/syslog-archive = no_root_squash

[AnonUID]
/share/CACHEDEV1_DATA/syslog-archive = 65534

[AnonGID]
/share/CACHEDEV1_DATA/syslog-archive = 65534
```

Then reload:
```bash
/etc/init.d/nfs.sh restart
```

---

## Step 6 — Wait for ArgoCD to sync

ArgoCD was bootstrapped in step 3. It will now pull and apply all workloads from:
- `day0-bootstrap` → cluster-level config
- `day1-foundation` → dhcpd, pxe-http, log-archiver, nfs-provisioner, syslog-server, sealed-secrets, cert-manager, ingress-nginx, ArgoCD apps
- `day2-services` → pihole
- `dhcpd-conf` → dhcpd ConfigMap

Monitor sync progress:
```bash
kubectl get applications -n argocd
```

Or via the UI: **https://192.168.2.10:30443** (admin / see ArgoCD secret below)

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

All apps should reach `Synced / Healthy` within ~5 minutes.

---

## Step 7 — Verify the cluster

```bash
# Both nodes Ready
kubectl get nodes

# All apps green
kubectl get applications -n argocd

# No broken pods
kubectl get pods -A | grep -v "Running\|Completed"

# dhcpd serving backend VLAN
kubectl logs -n infra deployment/dhcpd | grep Listening

# syslog-ng receiving logs from k8smaster (should be > 0)
kubectl exec -n logging deployment/syslog-ng -- syslog-ng-ctl stats | grep "s_network_tcp.*processed"

# per-host log dirs (one per forwarding node)
ls /srv/nfs/syslog-store/logging-syslog-storage-pvc-*/
```

---

## Key versions

| Component | Version | Pinned in |
|-----------|---------|-----------|
| ArgoCD | v3.2.0 | `variables/play/day0_bootstrap.yml` → `argocd_version` |
| kubeseal | v0.27.1 | `roles/install_required_software/tasks/install_required_software_curl.yml` |
| k3s | latest stable | `get.k3s.io` script — not pinned |
| pihole | 2024.07.0 | `day2-services/apps/pihole/pihole-deployment.yml` |

---

## Post-rebuild checklist

- [ ] Both nodes Ready (`kubectl get nodes`)
- [ ] All ArgoCD apps Synced/Healthy
- [ ] dhcpd listening on `LPF/end0/...`
- [ ] pinode-01 joins cluster
- [ ] pihole resolving DNS
- [ ] log-archiver CronJob completes at 02:00
- [ ] syslog-ng receiving logs (`syslog-ng-ctl stats` shows TCP processed > 0)
- [ ] Per-node log dirs present in `/srv/nfs/syslog-store/.../`
- [ ] ArgoCD UI accessible at https://192.168.2.10:30443
