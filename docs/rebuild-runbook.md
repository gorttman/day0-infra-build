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

> **Note — node onboarding now defaults to iSCSI-root, not NFS-root** (since 2026-08-17, see `roles/iscsi_netboot` and project memory `pinode01-iscsi-final` — this section above describes the legacy NFS-root path, still real and still used by `-e boot_mode=nfs`, but no longer what a plain `--tags manage_nodes` run onboards a new node onto). The iSCSI path has its own prerequisite this runbook doesn't otherwise cover: a golden image + LUN must already exist on the QNAP (`ansible-playbook day0-infra-build.yml --tags manage_iscsi`, run once and after any OS/kernel update — see `roles/iscsi_netboot/README.md` for the full sequence) before any node can be converted or onboarded onto it. On a from-scratch rebuild, run `--tags manage_iscsi` before `--tags manage_nodes` for this reason. Kernel is pinned to 6.12.47 in code (a real WiFi regression in 6.18.39, `roles/iscsi_netboot/tasks/install_iscsi_initiator.yml` enforces the pin) — don't let an unrelated apt upgrade silently move past it.

---

## Step 5 — QNAP: syslog-archive export

The log-archiver CronJob mounts `/syslog-archive` from valinor-m (192.168.1.30).

**Directory + NFS permissions are automated** (as of 2026-08-22) via:
```bash
ansible-playbook qnap-manage.yml --tags manage_qnap_main_pool_dirs,manage_qnap_exports
```
This creates `/share/CACHEDEV1_DATA/syslog-archive` and writes all 6
`nfssetting` sections correctly — but confirmed live that this alone
does **not** make the export actually appear (`showmount -e` won't
list it, `/etc/exports` won't contain it), because QTS needs the
directory registered as a real "Shared Folder" first, not just
present on disk. No `qcli_*` command was found that does this
registration. **One remaining manual step:** create the
`syslog-archive` Shared Folder once via the QTS web UI (Control Panel
→ Shared Folders → Create) before running the Ansible above — after
that one-time registration, this automation correctly manages its
permissions on every future run, same as pihole/calibre-web.

SSH access for any manual QNAP work: `ssh -i credentials/qnap_ansible_ed25519 admin@192.168.1.30` — the QTS admin account's `authorized_keys`, not the `admin`/`admin` password (retired 2026-08-07).

If a manual `nfssetting` edit is ever needed instead: it's `/etc/init.d/nfs restart` to reload, **not** `nfs.sh` (that script doesn't exist on this QTS version — confirmed the hard way, see `roles/qnap_exports/handlers/main.yml`).

---

## Step 6 — Wait for ArgoCD to sync

ArgoCD was bootstrapped in step 3. It will now pull and apply all workloads from:
- `day0-bootstrap` → cluster-level config
- `day1-foundation` → cluster/infra-tier apps (networking, storage provisioning, cert-manager, ingress-nginx, monitoring, and the ArgoCD Application definitions for the repos below)
- `day2-services` → the actual self-hosted app fleet (pihole, immich, paperless, jellyfin, arr-stack, books-pipeline, calibre-web, obsidian, vscode-server, postgres, and others — this list changes often; `kubectl get applications -n argocd` is the source of truth, not this doc)
- `dhcpd-conf` → dhcpd ConfigMap

Don't treat the app names above as exhaustive or use them as a rebuild checklist — see Step 7 for the actual verification command.

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

## Secrets applied outside ArgoCD

`infra/unifi-tf-secrets` is applied by Ansible
(`roles/unifi_tf_apply/files/unifi-tf-sealedsecret.yml`), not by the
app-of-apps. It carries no ArgoCD tracking annotation, so it reads as
unmanaged drift when auditing the cluster against Git. That is
expected. Every other SealedSecret in the cluster is ArgoCD-managed.

## Step 8 - Restore data

Steps 1-7 rebuild infrastructure and let ArgoCD redeploy the app fleet.
They restore no data. `/usr/local/bin/restore.sh` handles that, deployed
by `roles/backup_restore` during Step 3.

Run these in order - `ssh-keys` first, because every QNAP-targeting play
and every other restore stream depends on reaching the NAS:

    restore.sh list                 # what is restorable right now
    restore.sh ssh-keys             # ~/.ssh, needed before any QNAP play
    restore.sh sealed-secrets       # stage the newest key backup
    restore.sh postgres             # all databases, newest generation
    restore.sh adhoc                # manifests kept outside ArgoCD
    restore.sh qnap-data <source>   # per-export file restore

Every real restore asks for confirmation. To rehearse without touching
anything live, use `--dry-run`, or restore into a scratch target with
`postgres <db> --to <scratch-db>` / `qnap-data <source> --to <path>`.

Not covered by restore.sh: etcd. Snapshots are synced to
`/mnt/backup/k8smaster-etcd-snapshots` by a cron entry in
`roles/qnap_client`, and are restored with `k3s server
--cluster-reset --cluster-reset-restore-path=<snapshot>`, which is a
cluster-level operation rather than a data restore.
