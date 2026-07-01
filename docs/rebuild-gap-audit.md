# Rebuild Gap Audit — "Can we rebuild from code alone?"

**Date:** 2026-07-01
**Scope:** `day0-infra-build` (bare-metal → k3s + ArgoCD bootstrap) and its handoff into
`day0-bootstrap` (ArgoCD-managed cluster config). Question asked: if k8smaster's storage
were lost today, would `rebuild-runbook.md` + this repo's Ansible actually reproduce a
working cluster, with no undocumented manual steps or tribal knowledge?

Findings below are ranked by how badly they'd bite during an actual rebuild.

---

## Critical — would silently break a rebuild

### 1. Master's k3s `advertise-address` / `tls-san` fix isn't in code
`pi-1-inventory.md` §13b documents a 187-day-long broken `kubectl exec/logs` bug
(502 from the k3s tunnel), fixed live by writing to `/etc/rancher/k3s/config.yaml`:
```yaml
tls-san:
  - 192.168.1.10
advertise-address: 192.168.1.10
```
But `roles/install_required_software/tasks/post_install.yml` only ever writes
`write-kubeconfig-mode: "0644"` to that file — the advertise-address/tls-san lines
were never backported. **A rebuild from code today reproduces the exact same bug.**

### 2. Sealed-secrets private key has no restore path
Two separate mechanisms *back up* the sealed-secrets-controller key:
- `scripts/backup_sealed_secrets.sh` (host cron, every 5 min → weekly) →
  `day0-infra-build/credentials/sealed-secrets-key-*.yaml`
- `day0-bootstrap/apps/sealed-secrets/sealed-secrets-cron.yml` (in-cluster CronJob) →
  hostPath `/mnt/backup`

Nothing anywhere **restores** either backup. ArgoCD deploys the official
`bitnami-labs/sealed-secrets` `controller.yaml` fresh (pinned v0.27.0 via
`kustomization.yml`), which generates a brand-new keypair on every install. Every
`SealedSecret` already committed to `day1-foundation` / `day2-services` becomes
permanently undecryptable unless someone manually re-applies the old key secret
*before* the fresh controller generates its own. Not mentioned in
`rebuild-runbook.md` at all.

---

## High

### 3. Worker k3s agent join isn't automated anywhere
No task in the repo writes a worker's `/etc/rancher/k3s/config.yaml`
(`server:`, `token:`, `node-ip:`) or installs the k3s agent binary. The path
actually wired into the runbook (`nfs_netboot` role, tag `manage_nfs`) just clones
a **physically inserted, pre-built "golden image" SD card**
(`roles/nfs_netboot/tasks/import_from_sd_card.yml`) — an artifact whose contents
(including, presumably, however k3s-agent got onto it) live outside git entirely.
If that SD card is lost, corrupted, or goes stale, there is no scripted way to
reproduce it.

---

## Medium

### 4. Two contradictory, undocumented netboot-rootfs pipelines coexist
- **Path A (used):** `nfs_netboot` role → SD-card golden-image import. This is
  what `rebuild-runbook.md` Step 4 documents.
- **Path B (orphaned):** `day1-prep-netboot.yml` → `prep_rootfs` (debootstrap) +
  `prep_kernel` (from-scratch kernel build) + `publish_nfs_os`. Added early in
  git history (`55d24f5 Added nfs boot & root fs build`), never referenced by
  `README.md` or `rebuild-runbook.md`, and doesn't solve gap #3 either (no k3s
  agent config written there either).

Confusing dead/parallel code for anyone doing a rebuild under pressure — unclear
which is authoritative, and neither is complete on its own.

### 5. Pause-image pre-seed gap (already tracked)
New worker nodes have an empty containerd image store. First pod scheduled tries
to pull `rancher/mirrored-pause:3.6`; if DNS isn't up yet this fails silently and
pods hang in `ContainerCreating`. Documented in `BACKLOG.md` and
`pi-1-inventory.md` §9/§13 as a known chore, not yet fixed.

### 6. QNAP NAS `/syslog-archive` export is fully manual (already tracked)
No Ansible automation touches valinor-m (192.168.1.30). Documented in
`BACKLOG.md` and `rebuild-runbook.md` §5 as a known manual step — log-archiver
CronJob fails silently until it's done by hand.

---

## Needs a human answer (can't be verified from code)

### 7. Is `credentials/` actually backed up off-box?
This audit was run directly on k8smaster. `credentials/` (git PAT,
sealed-secrets key backups, wifi psk) is gitignored and local-only on this Pi.
`rebuild-runbook.md` Step 2 says "on a rebuild the `credentials/` directory
already exists on your secure backup — just copy it across" — but if the Pi's
storage itself is what's lost in a disaster scenario, this directory goes with
it unless it's mirrored somewhere else. Worth confirming an actual off-box copy
exists (1Password, another machine, etc.) rather than assuming it.

---

## What's solid (verified against `pi-1-inventory.md` line by line)

Fully captured in code and matching the live inventory exactly:
`prep_prerequisites` (`/etc/hosts`, cgroups in `cmdline.txt`, NTP servers, WiFi
NM connection, backend-vlan static IP), ArgoCD bootstrap + repo secrets, kubeseal
version pinning (v0.27.1 CLI / v0.27.0 controller — flagged in BACKLOG to
re-verify match before next rebuild), NFS server exports/`nfs.conf`, and
per-node rsyslog overlay automation (`setup_rsyslog_overlay.yml`, wired into
`add_node`).
