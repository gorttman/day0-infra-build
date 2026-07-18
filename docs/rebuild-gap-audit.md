# Rebuild Gap Audit — "Can we rebuild from code alone?"

**Date:** 2026-07-01
**Scope:** `day0-infra-build` (bare-metal → k3s + ArgoCD bootstrap) and its handoff into
`day0-bootstrap` (ArgoCD-managed cluster config). Question asked: if k8smaster's storage
were lost today, would `rebuild-runbook.md` + this repo's Ansible actually reproduce a
working cluster, with no undocumented manual steps or tribal knowledge?

Findings below are ranked by how badly they'd bite during an actual rebuild.

---

## Critical — would silently break a rebuild

### 1. Master's k3s `advertise-address` / `tls-san` fix isn't in code — RESOLVED 2026-07-01
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

**Fix:** `post_install.yml` now writes both values via `backend_vlan_ip` before
restarting k3s.

### 2. Sealed-secrets private key has no restore path — RESOLVED 2026-07-01
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

**Fix:** new task `roles/apply_bootstrap/tasks/restore_sealed_secrets_key.yml`,
included in `apply_bootstrap/tasks/main.yml` right before the bootstrap
Application is applied. It finds the newest
`credentials/sealed-secrets-key-*.yaml` (the host-cron backup) and applies it to
`kube-system` before ArgoCD deploys the controller. No-op on a truly first-ever
install where no backup exists yet. Note: this only covers the host-cron backup
location, not the in-cluster CronJob's `/mnt/backup` — fine for now since both
back up the same underlying secret, but worth remembering if the host-cron
backup ever stops running.

**Regression noted 2026-07-18:** it did stop running — silently, and for the
wrong reason to boot. `backup_sealed_secrets.sh` had been deliberately dropped
from `install_helper_scripts`'s `helper_scripts` list at some point (`# Removed
in favour of kubernetes cron job`), consolidating onto the in-cluster CronJob —
a reasonable call — but this restore task was never updated to match, and the
CronJob itself had two problems that meant it wasn't actually a working
replacement:

1. No `nodeSelector` — it scheduled onto whatever node was free (in practice,
   pinode-01, a diskless netboot node), writing to a `hostPath` this task never
   looked at. The backup was running the whole time, just somewhere
   unreachable during an actual rebuild.
2. It only captured the single newest key (`tail -n1` on the active-labelled
   set), not the full history. Existing committed `SealedSecret`s stay
   encrypted against whichever key was active when they were sealed — they are
   not re-encrypted on rotation — so a restore with only the newest key would
   still have permanently orphaned anything sealed against an older one.

Caught live: `crontab -l` for the (deprecated, never actually reinstated) host
mechanism was empty, and the one leftover file under `credentials/` predated
the most recent key rotation by three weeks. Re-running `install_day0` to "fix"
this would have made it worse — it still installs the old host-cron entry via
`ansible.builtin.cron`, pointing at a script the `helper_scripts` list no
longer deploys, producing a dead cron line that fails every 5 minutes. That
entry was removed again rather than kept.

Fixed properly instead: `sealed-secrets-cron.yml` now pins to k8smaster via
`nodeSelector: kubernetes.io/hostname: k8smaster` and writes directly into
`day0-infra-build/credentials/` (the same path this restore task reads), backs
up the full key set instead of just the newest one, and runs daily
(`0 4 * * *`) instead of its previous typo'd `* 10 * * *` (which actually meant
"every minute during the 10:00 UTC hour", not "every 5 minutes" as its own
comment claimed). `restore_sealed_secrets_key.yml` also gained a staleness
`assert` — if the newest backup on disk is more than 10 days old, the play now
fails loudly instead of silently restoring a key that's already missing the
current rotation. Took a fresh manual backup of all 9 live keys on the day of
this fix to close the immediate gap while the CronJob's corrected schedule
takes over.

---

## High

### 3. Worker k3s agent join isn't automated anywhere — RESOLVED 2026-07-01
No task in the repo writes a worker's `/etc/rancher/k3s/config.yaml`
(`server:`, `token:`, `node-ip:`) or installs the k3s agent binary. The path
actually wired into the runbook (`nfs_netboot` role, tag `manage_nfs`) just clones
a **physically inserted, pre-built "golden image" SD card**
(`roles/nfs_netboot/tasks/import_from_sd_card.yml`) — an artifact whose contents
(including, presumably, however k3s-agent got onto it) live outside git entirely.
If that SD card is lost, corrupted, or goes stale, there is no scripted way to
reproduce it.

**Fix:** two new tasks. `install_k3s_agent_base.yml` (called from
`configure_nfs_root_common.yml`, part of the `manage_nfs` flow) chroot-installs
the k3s agent binary + `k3s-agent.service` into the base rootfs with
skip-enable/skip-start (no token known yet at that point). `setup_k3s_agent_overlay.yml`
(called from `add_node`, part of `manage_nodes`) writes the actual join config
(`server: https://192.168.1.10:6443`, the live `node-token` read off k8smaster,
and `node-ip`) plus the enablement symlink into each new node's `/etc` overlay
— the same masking pattern `setup_rsyslog_overlay.yml` already handles for rsyslog.

**Caveat — not yet verified end-to-end.** This was written and syntax-checked
but not run against a real onboarding (no spare Pi/SD card in this session).
Before trusting it for the next real worker onboard: confirm `get.k3s.io`'s
`agent` positional argument + `INSTALL_K3S_SKIP_ENABLE`/`INSTALL_K3S_SKIP_START`
behave as expected inside the chroot (network access from chroot may need
checking), and confirm the existing golden-image-imported base rootfs doesn't
already have a k3s agent installed some other way that this would now
duplicate or conflict with.

---

## Medium

### 4. Two contradictory, undocumented netboot-rootfs pipelines coexist — RESOLVED 2026-07-01
- **Path A (used):** `nfs_netboot` role → SD-card golden-image import into
  `nfs_os_path` (`/srv/nfs/rpios/latest`, per `variables/play/day0_nfs_prep.yml`
  and `day1_node_prep.yml`). This is the path actually exported via NFS, referenced
  by the PXE `nfsroot=` kernel param, and what `rebuild-runbook.md` Step 4 documents.
- **Path B (orphaned):** `day1-prep-netboot.yml` → `prep_rootfs` (debootstrap) +
  `prep_kernel` (from-scratch kernel build) + `publish_nfs_os`. Added early in
  git history (`55d24f5 Added nfs boot & root fs build`), never referenced by
  `README.md` or `rebuild-runbook.md`, and doesn't solve gap #3 either (no k3s
  agent config written there either).

**Confirmed genuinely dead, not just undocumented:** Path B's own variables
(`variables/play/day1_prep_netboot.yml`) set `nfs_export_path: /srv/nfs`, and
`publish_nfs_os/tasks/to_nfs.yml` rsyncs the built rootfs to
`{{ nfs_export_path }}/base` — i.e. `/srv/nfs/base`. Nothing exports, mounts, or
references `/srv/nfs/base` anywhere else in either repo. Path B's output has
never actually reached a booting node.

This made Fix 12a's claim in `pi-1-inventory.md` (rsyslog install "baked into
`roles/prep_rootfs/tasks/configure_rsyslog.yml` for future rebuilds") misleading
— that task chroot-installed rsyslog into Path B's `staging_rootfs`, which was
never synced to the live `nfs_os_path`. The rsyslog fix that's actually live
today only got there because it was *also* applied by hand directly to
`/srv/nfs/rpios/latest` at the time.

**Fix:** deleted `day1-prep-netboot.yml`, `roles/prep_rootfs/`, `roles/prep_kernel/`,
`roles/publish_nfs_os/`, and `variables/play/day1_prep_netboot.yml` outright —
confirmed dead, no cutover attempted. Path A remains the one documented pipeline,
still dependent on the physical golden SD card (see item 7, and the still-open
"no build step for the OS content itself" observation below).

**New gap surfaced by this deletion — RESOLVED 2026-07-01:** installing rsyslog
into the *real* base rootfs (`nfs_os_path`) was not automated anywhere — it
never was in Path A, and the (non-functional) attempt to automate it lived
only in the now-deleted Path B. `setup_rsyslog_overlay.yml` only writes
per-node config; it assumes rsyslog is already present in the base image. A
true from-scratch rebuild (fresh golden SD card with no rsyslog pre-installed)
would have silently lost syslog forwarding until someone repeated Fix 12a by
hand again.

**Fix:** new task `roles/nfs_netboot/tasks/install_rsyslog_base.yml`
(mirroring `install_k3s_agent_base.yml`'s pattern), wired into
`configure_nfs_root_common.yml`. Chroot-installs the `rsyslog` package into
`nfs_os_path` and writes `etc/rsyslog.d/99-syslog-ng-forward.conf` there (using
the existing `syslog_server_ip`/`syslog_server_port` vars), so both files
`setup_rsyslog_overlay.yml` already copies out of the base rootfs
(`etc/rsyslog.conf` and the forwarding config) actually exist on a freshly
imported golden image. Not enabled in the base rootfs itself — same masking
reasoning as the k3s agent unit; enablement stays owned by
`setup_rsyslog_overlay.yml` per node.

**Caveat — not yet verified end-to-end**, same as item 3: no spare golden SD
card/node in this session to test a real `manage_nfs` + `manage_nodes` run
against it.

**Still open, not addressed by this deletion:** neither Path A nor the deleted
Path B ever provided an actual *build* step for the OS/kernel/initramfs content
— Path A only imports a pre-existing physical SD card image verbatim. Removing
Path B doesn't add or remove that capability; it only removes confusing dead
code that was never providing it in the first place.

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
