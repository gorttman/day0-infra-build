# Storage, Availability & Recovery Proposals

**Date:** 2026-07-11
**Status:** Proposals only — nothing in this document has been implemented.
No manifests, Ansible roles, or cluster state were changed while writing it.
**Scope:** Five gaps identified during the cross-repo IaC/rebuild deep dive
(`docs/rebuild-gap-audit.md` covered the day0-infra-build bootstrap path;
this covers gaps found in the GitOps-managed layer — day1-foundation /
day2-services — plus one day0-infra-build item):

1. The general-purpose NFS storage framework exists but is misconfigured.
2. `pinode-01` has a RAM-tmpfs disk-pressure problem with no code-level fix.
3. Jellyfin and the arr-stack are both node-pinned for SQLite-storage
   reasons, but need two different fixes, not one.
4. Pi-hole has no redundancy, and its one instance still uses the hard
   node-pin pattern that has already caused an outage once.
5. Sealed-secrets recovery has never been tested end-to-end and needs a
   deliberate, granular runbook rather than trusting it inside a full rebuild.

A sixth item (Cloudflare Tunnel routing living outside git) is noted at the
end but deliberately not designed here — Terraform is the planned fix, and
that work is being done in a separate session.

---

## 1. The NFS storage framework exists, but it's piggybacking on the syslog export

**Current state:** `day1-foundation/apps/nfs-provisioner/nfs-provisioner-storageclass.yml`
defines a real `nfs-client` StorageClass (`k8s-sigs.io/nfs-subdir-external-provisioner`
v4.0.2), and it's the default choice for most stateful apps — grafana,
syslog-server, homeassistant, mosquitto, kavita, obsidian, pihole, n8n,
paperless, and the postgres StatefulSet all already use it. So the
framework isn't *absent* — it's more used than not.

The problem: `nfs-provisioner-deployment.yml` points the provisioner's
`NFS_PATH` at `/srv/nfs/syslog-store` — the same export whose name and
purpose (per `day0-infra-build/docs/rebuild-runbook.md` and the
log-archiver CronJob) is specifically syslog archival. Every general
app-data PVC using `nfs-client` is actually being subdirectory-provisioned
underneath that path today. It works (nfs-subdir-external-provisioner just
makes per-PVC subdirectories), but it conflates two unrelated concerns
under one export: app data and log retention now share a directory, a
retention policy, and implicitly a growth/quota story, with no reason
other than that it was expedient at the time.

**Proposal:**
- Add a dedicated export in `day0-infra-build`'s NFS setup
  (`roles/nfs_netboot/tasks/setup_nfs_server.yml` + `templates/exports.j2`),
  e.g. `/srv/nfs/k8s-storage`, alongside the existing `rpios`, `cluster`,
  and `syslog-store` exports — same pattern, new directory.
- Point `nfs-provisioner-deployment.yml`'s `NFS_PATH`/volume at the new
  export instead of `/srv/nfs/syslog-store`.
- Migrate existing subdirectories: since `reclaimPolicy: Retain` +
  `archiveOnDelete: "true"` is already set, no PVC currently has its data
  at risk from a StorageClass change, but existing PVCs would need to be
  recreated to point at new subdirectories (same caveat `jellyfin-pvcs.yml`
  already documents for its own future `local-path` → NFS swap) — this is
  a real migration with a maintenance window, not a hot edit.
- Document the storage tiers as a single table in a new
  `day1-foundation/docs/storage-architecture.md`: `nfs-client` (general app
  data, subdir-provisioned), `local-path` (node-local, non-durable, used
  where SQLite-on-NFS would corrupt or performance matters), `qnap-static`
  (large media, hand-provisioned PV against the QNAP NAS directly).

**Availability note:** the NFS server backing all of this
(`day1-foundation/apps/nfs-server`) is a single Deployment, hostPath on
k8smaster, hostNetwork — there is no failover. For a two-node homelab this
is a reasonable, deliberate trade-off (k8smaster is the only node with
real disk anyway), but it should be written down as an *accepted* risk in
the new storage-architecture doc rather than left implicit — right now
nothing states that all persistent data has a single point of failure.

---

## 2. `pinode-01` disk pressure: split the image store from local-path storage

**Root cause (already captured in memory, restated for the doc trail):**
`pinode-01` netboots via NFS root, and overlayfs — which both containerd's
image store and the k3s `local-path` provisioner need — can't sit directly
on an NFS mount. The current workaround is a single 4G **tmpfs** covering
all of `/var/lib/rancher/k3s`. The actual observed failure (the Jellyfin
image eviction loop, per memory) was specifically `runtime.imageFs`
pressure — i.e. the containerd image/snapshotter store filling up — not
`local-path` PVC data. The existing mitigation is entirely social
convention — pin large-image/local-path workloads to k8smaster by hand
(`jellyfin`, the `*-arr` stack, `influxdb`, `portainer` all do this today)
— there is no code-level fix.

**Proposal — split the two concerns onto two different backing stores
instead of moving everything:**

`/var/lib/rancher/k3s/agent/containerd/` (images + snapshotter, the thing
that actually overflowed) and `/var/lib/rancher/k3s/storage/` (the
`local-path-provisioner` root) are already separate subdirectories with no
cross-dependency — containerd only needs to hardlink within its own
directory tree, so they can safely live on different filesystems.

1. **Move only the containerd image store to NFS**, via the same
   per-node loopback-ext4-on-NFS mechanism as originally proposed: a
   sparse file per node under `{{ nfs_cluster_path }}/pinode-<mac>/containerd-data.img`,
   `mkfs.ext4` once, mounted at `/var/lib/rancher/k3s/agent/containerd`
   via a systemd `.mount` unit ordered `Before=containerd.service` /
   `Before=k3s-agent.service`, following the same per-node-overlay
   pattern `cluster-overlay.service.j2` already uses. This gets images
   458G of headroom instead of a hard 4G ceiling — directly fixing the
   eviction-loop symptom that was actually observed.
2. **Leave everything else — including `storage/` — on tmpfs, unchanged.**
   Any `local-path` PVC, and by extension anything SQLite-sensitive that
   might ever land there, keeps exactly the RAM-speed IO and local
   durability characteristics it has today. Nothing is proposed to move
   onto NFS-backed storage that wasn't already fine with the reboot-wipe
   behavior tmpfs already has — this design introduces no new corruption
   exposure for SQLite or anything else, because nothing durability-
   sensitive crosses to NFS in this version.
3. **Free side-effect:** once images no longer share the tmpfs, it can be
   shrunk from 4G to something much smaller (images were almost certainly
   the dominant consumer) — RAM back for actual workloads, which matters
   more on an 8G Pi than the raw number suggests.

**Trade-offs, still worth stating plainly:**
- Image pulls/extracts now cross the network to the NFS server — slower
  than RAM for a cold pull, but this is a one-time cost per image, not a
  running hot path, so it's a good trade for headroom.
- A loop-mounted filesystem is less forgiving of a mid-write NFS
  interruption than a native NFS mount or RAM. A network blip while the
  loop device is mid-write is a real corruption risk for the image store
  specifically — recoverable by re-pulling images (`k3s ctr images pull`,
  already the documented pre-seed workaround pattern), not by losing
  application data, since no application data lives there.
- Test against a real second node before trusting it — same
  "written and reasoned through, not yet run against real hardware"
  caveat as `install_k3s_agent_base.yml` / `setup_k3s_agent_overlay.yml`.

**Alternatives, for completeness (both already noted in memory, still
valid, not recommended as first choice):**
- Buy pinode-01 real local storage (USB SSD boot or NVMe HAT) — simplest,
  most reliable, costs money and a physical change, and reopens the
  "diskless netboot" design goal.
- Just enlarge the tmpfs — free, zero new failure modes, but spends scarce
  RAM and never gives images real room to grow.

---

## 3. Jellyfin and the arr-stack: two different fixes, not one

Both are pinned to k8smaster today for the same underlying reason —
SQLite config DB, on `local-path`, which can't safely be RAM-volatile (data
loss) or direct-NFS (corruption). But they don't need the same fix: the
arr-stack has an escape hatch Jellyfin doesn't.

### Part A — arr-stack: migrate off SQLite entirely onto the existing Postgres instance (firm proposal)

Recent versions of the arr suite (Sonarr, Radarr, Prowlarr, Bazarr and
siblings) support pointing the app at an external PostgreSQL database
instead of its bundled SQLite file. `day2-services` already runs an
unpinned, `nfs-client`-backed Postgres `StatefulSet` that other apps
already use — so the fix is to point the arr-stack at that same instance
instead of inventing anything new:

1. Create one database + role per app in the existing Postgres instance
   (e.g. `arr_sonarr`, `arr_radarr`, ...), credentials issued as
   SealedSecrets, consistent with how every other app's DB credentials are
   already handled in this project.
2. Configure each app's Postgres connection per its own documented config
   (exact env vars/config-file keys differ per app — check each app's
   current docs at implementation time; not a blocker for this proposal,
   just an implementation detail).
3. Drop the `local-path` PVC and the `nodeSelector`/pin entirely once each
   app is migrated and verified against its new database — the pin
   disappears completely, the same way Postgres itself has no pin today.
4. Note this only covers the *config* database. Any actual downloaded
   media/working directories are separate volumes already, and aren't
   part of the node-pinning problem this section addresses.

This is the cleanest of all the fixes in this document — it doesn't add
new infrastructure (RAM sizing, backup cadence, a new sidecar) or new
failure modes, it just uses a storage backend the project already runs
and already trusts, the same way Postgres itself already floats.

### Part B — Jellyfin: no Postgres option, so upgrade the Kavita/Pi-hole pattern instead

Jellyfin's core is built on EF Core tightly coupled to SQLite, with (as
far as I'm aware) no supported Postgres backend — worth a quick check
against current Jellyfin release notes if this matters, since that's the
kind of thing that can change and my knowledge has a cutoff, but I
wouldn't plan around it existing.

**Proposed design — Litestream sidecar, replacing the tar-backup pattern
with near-continuous replication:**

1. Jellyfin's SQLite files live on a RAM `emptyDir`, same base idea as the
   existing Kavita/Pi-hole pattern (fast, safe local semantics, any node).
2. A **sidecar container** in the same pod, sharing that `emptyDir`, runs
   `litestream replicate` — it tails the SQLite WAL and continuously ships
   changed frames to a replica destination, instead of waiting for a
   periodic cron+tar job. Jellyfin's own process never knows it's there;
   it just opens its SQLite file normally.
3. An **initContainer** runs `litestream restore` against the same
   destination before Jellyfin's main container starts, pulling the latest
   consistent snapshot + replayed WAL into the empty RAM volume — this is
   a drop-in replacement for the tar-restore initContainer Kavita already
   uses.
4. **The one real unknown, not glossed over:** Litestream's mainstream
   replica target is S3-compatible object storage. I'm not fully certain
   whether current versions cleanly support a plain NFS/file-path
   destination — that needs confirming against its docs before committing
   to this design. If it turns out to require S3, the practical option is
   self-hosting a small MinIO instance in-cluster (itself sitting on
   `nfs-client` storage) — which sounds like it reintroduces NFS, but
   doesn't reintroduce the *SQLite*-on-NFS problem, since Jellyfin/Litestream
   would talk to MinIO over its object API, never touching a raw NFS mount
   directly with SQLite semantics.
5. **What this buys you over Kavita's plain tar approach:** a much smaller
   data-loss window on an ungraceful pod death — continuous WAL shipping
   (typically low single-digit seconds of lag) instead of "whatever the
   cron interval is." **What it doesn't buy you:** this is still one
   active writer at a time, not live multi-instance HA — it makes
   failover/restart faster and safer, it doesn't let two Jellyfin pods run
   against the DB simultaneously.
6. **Recommend a small spike before wiring this into Jellyfin for real**:
   deploy Litestream against a disposable SQLite file in a scratch
   namespace, confirm a replicate→kill-pod→restore round trip actually
   works against whichever destination is chosen. This is new tooling to
   the project — unlike the RAM+tar pattern, which is already proven live
   for Kavita and Pi-hole.
7. **Fallback if the destination requirement is unwelcome** (e.g. you'd
   rather not stand up MinIO): keep the existing RAM-`emptyDir` +
   periodic-tar-to-`nfs-client` + initContainer-restore pattern, just
   tuned for Jellyfin specifically — a tighter backup interval given
   Jellyfin's higher write rate than Kavita, and a `emptyDir` size budget
   that accounts for its larger metadata/thumbnail footprint (this also
   needs weighing against the RAM freed up by section 2's image-store
   move, since both draw from the same node RAM budget).

---

## 4. Pi-hole: fix the known-bad hard pin, then add real redundancy

**Current state, and why it matters:** `day2-services/apps/pihole/pihole-deployment.yml`
still has:
```yaml
nodeSelector:
  kubernetes.io/hostname: pinode-01
```
This is exactly the pattern memory already flagged as having caused a real
outage on 2026-07-09 (pinode-01 hit the tmpfs disk-pressure issue above,
and hard-pinned Pi-hole had nowhere to fail over to — it sat `Pending`
until the node self-healed). The project's own established fix for this —
the soft `workload-affinity` convention in `day1-foundation/README.md` /
`ansible/label-nodes.yml` (weight-100 `preferredDuringSchedulingIgnoredDuringExecution`,
never `required`) — has since been adopted by grafana, the `*-arr` stack,
homeassistant, and n8n, but **Pi-hole itself was never migrated**, and
neither was jellyfin (which uses the same hard `nodeSelector` pattern, for
a different, currently-valid reason — its config PVC's SQLite DB can't
safely move to NFS, and its comment already tracks that). This is a real,
currently-live inconsistency: the fix exists in the codebase and is proven
in three other apps, but the one workload the outage was actually about
still isn't using it.

**Proposal, two parts:**

**Part A — minimum fix: convert Pi-hole to the existing soft-affinity pattern.**
Add `pihole: {primary: pinode-01}` to `workload_affinity` in
`day1-foundation/ansible/label-nodes.yml`, and replace the hard
`nodeSelector` in `pihole-deployment.yml` with the reusable
`day2-services/components/workload-affinity/affinity-patch.template.yml`
patch, the same way grafana/n8n/homeassistant already consume it. This
alone would have prevented the 2026-07-09 outage and costs nothing — it's
a direct application of a pattern this project already trusts.

**Part B — actual redundancy: two independent Pi-hole instances, never on the same node.**
This is what "dual pihole" should mean, and it needs more than an affinity
tweak — a naive second replica sharing the *same* PVC would reproduce the
exact SQLite-on-NFS corruption incident already on record for Pi-hole's
`gravity.db`. Two Pi-hole pods cannot safely share one gravity database
over NFS. The standard community pattern for Pi-hole HA (used widely
outside k8s too, via tools like `gravity-sync`/`nebula-sync`) is two fully
independent instances kept in sync out-of-band, not a shared backend —
map that onto this project's existing idioms:

- **Two Deployments**, `pihole-primary` (today's `pihole`, kept as-is
  functionally) and `pihole-secondary` (new), each with its **own**
  `nfs-client`-backed PVC — independent `gravity.db`/`pihole-FTL.db`, no
  shared storage.
- **Soft workload-affinity**, opposite preferences: `pihole-primary` prefers
  `pinode-01`, `pihole-secondary` prefers `k8smaster` — reusing the exact
  mechanism from Part A, so this is additive, not a new concept.
- **Pod anti-affinity** on `app: pihole` /
  `topologyKey: kubernetes.io/hostname`, `preferredDuringScheduling` (not
  `required` — two nodes total means a `required` anti-affinity would
  leave the secondary permanently `Pending` if the primary's node ever
  needs both pods during an event). This is a belt-and-braces backstop on
  top of the opposite affinity preferences, guarding against both
  preferences quietly pointing at the same node after a future relabel.
- **No live sync tool needed between the two instances.** The part of
  Pi-hole's config that actually matters for DNS correctness — custom
  records, AAAA suppression, split-horizon entries — is already declared
  as code in `dns-conf/pihole/pihole-custom-dns-cm.yml`, mounted into the
  Pod, and ArgoCD-synced independently to each instance. Point both
  `pihole-primary` and `pihole-secondary` at that same ConfigMap (each
  gets its own copy via its own Application/sync, same source) and they
  converge on identical config automatically, the same way any other
  ArgoCD-managed app with two replicas would — no Teleporter export/import
  or `gravity-sync`/`nebula-sync` job required. The two instances' local
  `gravity.db`/query-log state (independent PVCs, per below) is expected
  to diverge — that's fine, it's not config, just runtime state — but
  neither one is a source of truth for the other. The one thing this
  depends on: nothing config-relevant may be left as a manual pihole-UI-only
  edit that never makes it into `dns-conf` — if that ever happens it would
  only apply to whichever instance someone happened to click into.
- **A second MetalLB VIP** for the secondary Service (alongside the
  existing `192.168.2.240` primary), and both handed out as primary/secondary
  DNS servers via DHCP (`dhcpd-conf`) — standard dual-DNS-server client
  behavior (try primary, fall back to secondary on timeout), no special
  client-side failover logic needed.
- Document all of this in a new `day2-services/apps/pihole/README.md` —
  today there is no README for this app at all, and this is exactly the
  kind of non-obvious, multi-repo, multi-decision design that needs one.

---

## 5. Sealed-secrets: a granular recovery runbook, not just "part of the big rebuild"

**Why this needs its own runbook, not just a line in `rebuild-runbook.md`:**
losing the sealed-secrets controller's key is uniquely unforgiving — every
`SealedSecret` already committed across `day1-foundation`/`day2-services`
becomes permanently undecryptable if the wrong key ends up in the
controller. The restore mechanism (`roles/apply_bootstrap/tasks/restore_sealed_secrets_key.yml`)
is real code, already wired in, but per its own audit trail
(`docs/rebuild-gap-audit.md` item 3's caveat pattern) has never been
exercised end-to-end, and has two known soft spots:

- It only searches `credentials/sealed-secrets-key-*.yaml` (the host-cron
  backup location) — not the in-cluster CronJob's `/mnt/backup` location.
  Fine while both stay in sync, silently wrong the day the host cron stops
  running and nobody notices.
- The in-cluster backup CronJob's own schedule doesn't match its
  documented intent (`"* 10 * * *"` vs. the "every 5 minutes" comment
  above it) — a second, independent reason the two backup sources could
  drift apart without anyone seeing an error.
- kubeseal CLI (v0.27.1) and the controller image (v0.27.0) are still
  mismatched — tracked in `BACKLOG.md`, unresolved, and directly relevant
  here: a version mismatch is exactly the kind of thing that only surfaces
  *during* a real recovery, at the worst possible time to discover it.

**Proposed runbook — `docs/sealed-secrets-recovery-runbook-proposal.md`,
tested in isolated stages rather than only as part of a full teardown:**

1. **Stage 0 — dry-run verification, no cluster impact.** Confirm
   `kubeseal --version` matches the controller's actual running image tag
   (`kubectl get deployment sealed-secrets-controller -n kube-system -o
   jsonpath='{.spec.template.spec.containers[0].image}'`, per the existing
   BACKLOG chore) *before* ever relying on a restore. Fix the version pin
   first if mismatched — restoring a key into a controller whose kubeseal
   can't produce compatible output is a wasted recovery.
2. **Stage 1 — backup provenance check.** Confirm both backup sources
   (`credentials/sealed-secrets-key-*.yaml` and the in-cluster
   `/mnt/backup` CronJob output) exist, are recent, and are byte-identical
   (same underlying secret, different export paths) — this is the point
   to also fix the schedule bug and extend `restore_sealed_secrets_key.yml`
   to check both locations, preferring whichever is newest.
3. **Stage 2 — isolated restore test.** Rather than testing this by
   rebuilding the whole cluster, delete only the sealed-secrets namespace
   and its controller Deployment, re-run just the `apply_bootstrap` role's
   `restore_sealed_secrets_key.yml` + ArgoCD resync for the sealed-secrets
   Application, and confirm one already-deployed `SealedSecret` (pick a
   low-stakes one) still decrypts correctly. This proves the restore path
   works without touching anything else — the "bit by bit" approach
   instead of an all-or-nothing full rebuild as the only way to find out.
4. **Stage 3 — document the failure mode.** Explicitly write down what
   happens if restore fails (every `SealedSecret` needs to be manually
   re-sealed against a new key and re-committed) so it's a known,
   estimable recovery cost rather than a surprise.

---

## 6. Cloudflare Tunnel (noted, not designed here)

Both `day1-foundation`'s `cloudflared` and `day2-services`'s
`books.i3sec.com.au` kavita ingress depend on tunnel routing rules that
live only in the Cloudflare dashboard — confirmed not reproducible from
git alone. The intended fix is to manage the tunnel's ingress/DNS config
via Terraform (Cloudflare provider) instead, which is being built in a
separate session — no design work is proposed here. Once that lands,
`day0-infra-build/BACKLOG.md`'s stale "Cloudflare Tunnel: not currently
deployed" line should also be corrected (it's deployed today; the gap is
config-as-code for its routing, not deployment).
