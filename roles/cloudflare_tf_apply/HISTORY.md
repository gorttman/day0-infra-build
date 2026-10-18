# cloudflare-tf: build history, mistakes, and fixes

Full narrative of building this app, for institutional memory. If
something looks weird in the code, the answer is probably in here.

## The goal

Bring Cloudflare Zero Trust config that already existed as manual
dashboard clicks (a WAF rule enforcing mTLS on a few self-hosted apps,
plus the tunnel's Public Hostname routing) under Terraform, run in-cluster
by an Argo CD Sync-hook Job. End state: exposing a new service through
Cloudflare should be "add a hostname to a variable," not a sequence of
dashboard screens.

## What it took to get there

### 1. ConfigMap convention deviation (by design, not a mistake)

Every other ConfigMap-from-files setup in this cluster
(`dhcpd-conf`, `dns-conf/coredns`) sets `disableNameSuffixHash: true` for
a stable name, because they feed long-running Deployments that reload
their own config. This app deliberately does the opposite — keeps
Kustomize's default hash suffix — because the ConfigMap feeds a one-shot
Argo CD Sync hook Job, and the hook only re-fires when its own pod spec
changes. A stable ConfigMap name would mean editing a `.tf` file changed
the ConfigMap's contents but not the Job's spec, and Argo would never
notice. See the README for the full reasoning.

### 2. vscode: back-and-forth on how to expose it

Early mistake: assumed vscode's public path had to go through
`ingress-nginx` the same way argocd/books do, and built a whole parallel
nginx-based Ingress + auth setup from scratch. Got corrected: the actual
ask was "treat it exactly like every other app on the tunnel" (i.e. yes,
the standard `ingress-nginx` path, not a special case) — a real
back-and-forth caused by not asking early enough what "treated the same"
actually meant. Ended up, correctly, building a proper `ingress-nginx`
Ingress for vscode (`vscode-public-ingress.yml` /
`vscode-public-auth-ingress.yml` in `day2-services`), matching the
existing `books`/kavita pattern, keeping vscode's own PAM auth as
defense-in-depth alongside the Cloudflare-edge mTLS gate (explicit
decision: every app keeps its own auth, no exceptions).

### 3. NFS-backed emptyDir breaks Terraform's state lock

First real Job failure: `terraform init` failed immediately with
`Error acquiring the state lock: ... no locks available`. Root cause:
this node's default `emptyDir` is NFS-backed with `local_lock=none`, and
NFS's advisory locking is disabled on that mount, so any `flock()` call
fails with `ENOLCK`. Terraform needs a real file lock for state locking
even when using the `pg` backend. Confirmed empirically with two
throwaway test pods on the same node (`flock` fails on default
`emptyDir`, succeeds with `medium: Memory`). Fix: `tf-workspace`'s
`emptyDir` uses `medium: Memory` (tmpfs) in `cloudflare-tf-job.yml`. Same
underlying issue as an earlier Pi-hole/SQLite incident on this cluster.

### 4. tmpfs sizeLimit too small

Second failure, after the above fix: `no space left on device` while
*installing* the Cloudflare provider binary. The provider alone is
~228Mi (confirmed via a local `terraform init`) — the initial `64Mi`
sizeLimit was a guess that didn't account for that. Bumped to `512Mi`.

### 5. Argo CD sync lag, repeatedly

Multiple times, pushing a fix to `main` didn't make the Job re-run with
the new manifest — Argo CD's Application stayed synced to the *previous*
commit until its next git-polling cycle, so retrying just reran the old,
already-broken config. Worked around each time with:
```bash
kubectl patch application -n argocd cloudflare-tf --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
# and, when a refresh alone didn't trigger a new sync (hooks don't
# participate in normal drift detection the way regular resources do):
kubectl patch application -n argocd cloudflare-tf --type merge \
  -p '{"operation":{"sync":{"revision":"<commit-sha>","prune":true}}}'
```
Also learned: Sync-hook pods get cleaned up (per `hook-delete-policy`)
fast enough that watching via Argo's own retry loop can miss the chance
to read logs. Running the exact same command manually in a throwaway
pod (same image, same ConfigMap, same secret) sidesteps this entirely
and lets you watch synchronously.

### 6. WAF ruleset collided with a pre-existing manual one

Once the Job actually ran, `terraform apply` failed:
`exceeded maximum number of zone rulesets for phase
http_request_firewall_custom` — Cloudflare allows only one custom
ruleset per phase per zone, and one already existed (`name: "default"`,
`last_updated: 2026-07-09` — the mTLS rule that was created manually
before this whole project started, i.e. the very thing this project
exists to codify). Fix: `terraform import` to adopt the existing
ruleset by ID before applying. One real side effect: because the
imported ruleset's `name` differs from ours, Terraform treats renaming
it as forcing a replace (destroy-then-create), so there was a genuine
~1 second gap with no WAF rule active during that one cutover.

### 7. DNS records are a separate resource from tunnel ingress

`argocd`/`books`/`qnap` already had public DNS records (auto-created
by the dashboard's "Public Hostname" wizard when they were originally
set up manually) — but that wizard does two things atomically: it adds
the tunnel ingress rule *and* creates the DNS record. Terraform's
provider models these as two unrelated resources
(`cloudflare_zero_trust_tunnel_cloudflared_config` for ingress,
`cloudflare_dns_record` for DNS) — nothing does both. Since our
Terraform only ever wrote the first, vscode's ingress rule went live but
it had no DNS record, so it wasn't reachable at all from outside. Fixed
by adding `cloudflare_dns_record` (type `CNAME`, content
`${tunnel_id}.cfargotunnel.com`, proxied), importing the 3 existing
records, letting Terraform create the missing one for vscode.

### 8. Security incident: token briefly exposed in this session

A diagnostic `curl -v` call echoed the full `Authorization: Bearer
<token>` header into command output during troubleshooting. Caught and
flagged immediately; recommended rotating the Cloudflare API token as a
precaution. Lesson: never use verbose curl output with a real
`Authorization` header present — redirect stderr away or strip the
header from any debug output before it's ever printed.

### 9. API token permission gaps, twice

The Cloudflare API token was scoped only for what was assumed necessary
up front (Zone WAF Rulesets, Tunnel config). Hit `Authentication error`
(403) on:
- the DNS records endpoint (needed **Zone → DNS → Edit**)
- the Client Certificate hostname-associations endpoint (needed
  **Zone → SSL and Certificates → Edit**)

Both were existing-token permission edits (no new token, no re-sealing
needed) — but each one was only discovered by hitting the wall, not
anticipated. Lesson: when a project touches N different Cloudflare API
surfaces, check required permissions for all of them up front rather
than one at a time.

### 10. Found and cleaned up an unrelated broken config: k8smaster

While reading the live mTLS Client Certificate hostname list to confirm
our plan wouldn't clobber anything, `k8smaster.i3sec.com.au` turned up —
completely unknown to our Terraform, left over from an earlier, separate
attempt (outside this project) at browser-based SSH access via the same
tunnel. A sweep across DNS records, tunnel ingress, the mTLS hostname
list, and Cloudflare Access Applications found:
- a DNS record (CNAME to the tunnel)
- **no** tunnel ingress rule (already gone, apparently by accident, from
  an earlier Terraform apply that never listed it)
- still present in the mTLS Client Certificate hostname list
- a Cloudflare Access Application named "k8smaster" with **`"policies":
  []`** — an empty policy list, which lines up exactly with the
  symptom that started the whole side-quest ("wants email confirmation
  and never sends it" — an Access app with no policy has nothing telling
  it who's allowed in).

Confirmed with the user this was "all wrong config" and should be
removed entirely, not migrated in. Deleted the Access Application and
the DNS record directly (neither was ever Terraform-managed); the
Terraform-managed mTLS hostname list correctly dropped it on the next
apply, simply by never including it in `tunneled_hostnames`.

### 11. The mTLS "Hosts" list is a *third* separate setting

Believed (from the original project brief) that the SSL/TLS → Client
Certificates hostname list "has no Terraform resource, stays manual."
That was wrong — outdated information, not re-verified. The resource
`cloudflare_certificate_authorities_hostname_associations` exists. This
setting matters because it's what makes Cloudflare's edge *request* a
client certificate during the TLS handshake at all, before the WAF rule
(which only *checks* whether a cert was presented) ever runs. Without a
hostname in this list, a browser is never prompted for a cert and the
WAF rule just always blocks — which looks identical to a broken WAF rule
from the outside, but isn't. vscode was missing from this list even
after the WAF rule and tunnel were both correct. Added the resource,
imported the existing list, applied — now covers all four hostnames.

### 12. vscode's 404 → 500 → 414 progression

Once DNS, tunnel routing, WAF, and the mTLS hosts list were all
correct, vscode still didn't work — in stages:
- **404**: actually stale negative DNS caching on Pi-hole (the zone's
  SOA negative-cache TTL is 1800s) from before the record existed.
  Fixed with `pihole restartdns`.
- **403 with no prompt**: expected — the WAF rule correctly blocking a
  request with no client cert (confirmed by reproducing the identical
  403 against `argocd.i3sec.com.au`, a known-working host, with no cert).
- **500**: the real bug. `auth_server.py`'s `/verify` endpoint returns
  `302` (with a `Location` header) when unauthenticated — which
  Traefik's `forwardAuth` middleware passes straight through to the
  browser (hence internal access worked fine), but nginx's
  `auth_request` module only accepts `2xx`/`401`/`403` from the auth
  subrequest; anything else, including `302`, is treated as an internal
  error. Confirmed via `ingress-nginx-controller`'s own logs:
  `auth request unexpected status: 302`. Fixed by changing `/verify` to
  return `401` with an HTML body containing a client-side (meta-refresh
  + JS) redirect — Traefik still passes this through unaltered so the
  internal path is unaffected, and nginx's `auth-signin` annotation
  builds its own redirect on seeing `401`. Verified this didn't reopen
  the original reason the code used a redirect instead of Basic-Auth
  (Safari not resending Basic-Auth credentials on a WebSocket upgrade) —
  that was already fixed by the existing cookie-session approach, and
  only affects the very first unauthenticated page load, never a
  WebSocket request.
- **414 Request-URI Too Large**: a second, genuine bug introduced by the
  401 fix. `vscode-public-ingress.yml`'s auth-required path regex
  (`/gorttman(/|$)(.*)`) also matched `/gorttman/auth` — the login page's
  *own* path, served by a separate, non-auth-required Ingress
  (`vscode-public-auth`). nginx's location-matching rules mean a
  matching regex location always wins over a matching plain-prefix
  location, even when the prefix is more specific — so the login page
  itself was being sent through the same auth check, creating an
  infinite loop (401 → redirect to login → login page hits the same
  auth check → 401 again → redirect, nesting the URL deeper each hop)
  until nginx rejected the ever-growing URL outright. Fixed with a
  negative lookahead (`/gorttman(?!/auth(?:/|$))(/|$)(.*)`) excluding the
  login path from the auth-required regex.

### 13. Validation: homeassistant, added cleanly

First real test of the runbook on a genuinely new app, after all of the
above was fixed. Homeassistant handles its own login internally (no
forward-auth microservice like vscode's), so it only needed: one
hostname added to `tunneled_hostnames` (no `origin` override), one new
`ingressClassName: nginx` Ingress in `day2-services` with no auth
annotations at all, both repos committed and merged in the same
dependency order as before (`day2-services` first). Result: `terraform
apply` reported exactly `1 added, 3 changed, 0 destroyed` (new DNS
record; tunnel config, WAF rule, and mTLS hostname list each updated
in-place) and worked first try. Confirmed live via DNS and a `403` on
the mTLS gate immediately after. Only manual step needed was the same
Argo CD sync-lag workaround as always (hard refresh + explicit
`.operation.sync` patch) — everything else was genuinely just "add a
hostname to a variable," as originally intended.

### 14. WARP client access for SSH to k8smaster

Separate from the tunneled-hostname/mTLS system above: added
`warp.tf` so `gorttman@i3sec.com.au` and `brett@i3sec.com.au` can SSH to
k8smaster (`192.168.2.10`) from anywhere via Cloudflare WARP, ahead of
travel. Distinct from #10's abandoned k8smaster Access App (browser-
terminal `self_hosted` type, built manually, empty policy list, deleted)
— this is the WARP-client model instead: WARP just supplies network
reachability to a private IP, actual SSH auth is still the existing key,
unchanged.

Key discovery mid-build: read the live device default profile via a
throwaway diagnostic pod before writing any `.tf`, and found the
account's default WARP split-tunnel config already excludes
`192.168.0.0/16` (standard stock default, so WARP doesn't swallow LAN
traffic for typical use). A private network route on the tunnel alone
wouldn't be enough — the device profile's split-tunnel setting decides
what a WARP-enrolled client actually sends through the tunnel in the
first place. Provider schema research (pulled locally via
`terraform providers schema -json` against the pinned `~> 5.0` version,
rather than trusting training-data memory of the resource shape) turned
up the actual constraint: `include` and `exclude` on
`cloudflare_zero_trust_device_default_profile` are mutually exclusive —
the API rejects both being set. Punching a single `/32` hole in the
existing `/16` exclude wasn't an option; the only ways to get k8smaster
routed were (a) enumerate ~16 complement CIDRs to exclude "the `/16`
minus one address," or (b) switch the whole profile to `include` mode
with just that one address. Went with (b): this account has no other
Zero Trust use case yet (no Access apps existed at all before this —
Access Apps list came back empty), so "everything except k8smaster
bypasses WARP" has no other traffic to break. Documented as a real
trade-off to revisit in the README if that ever stops being true.

Also added a `warp`-type `cloudflare_zero_trust_access_application`
with an inline policy restricting *enrollment* to those two emails —
without it, the account's only IdP (`onetimepin`, no domain
restriction) would let anyone who can receive mail at a self-typed
address enroll a device and inherit this same split-tunnel config.

Confirmed via the Cloudflare provider's own `docs/resources/*.md` at
the exact pinned tag (`v5.22.0`, fetched from GitHub, not the JS-
rendered registry site which returned no usable content) — the
`warp` value for `type`, the mutually-exclusive `include`/`exclude`
constraint, the attribute-assignment HCL syntax (`include = [{...}]`,
not block syntax) for nested-attribute schemas, and the device default
profile's import ID format (`<account_id>`, no separate profile ID
needed). Validated locally with `terraform validate` (via a throwaway
`hashicorp/terraform` Docker container, `-backend=false`, dummy token/
zone_id) before ever proposing an apply — caught one real mistake this
way: `exclude = []` still counts as "exclude is set," so it collided
with `include` in the same validate pass and had to be dropped entirely
rather than zeroed out.

Initial plan was to import the pre-existing device default profile the
same way #6/#7/#11 did — a one-off `terraform import` CLI command run
by hand before the first apply. Pushed back on: that's a manual step
living only in this file's prose, not in code — if the Postgres state
backend were ever rebuilt from scratch, nothing would remind a future
apply to run it again, and `apply` would just fail on "already exists"
the way #6 originally did. Fixed by using a declarative `import` block
in `warp.tf` instead (stable since Terraform 1.5, this repo already
requires `>= 1.7.0`): a no-op when the resource is already in state,
an automatic adopt-instead-of-create when it isn't. Confirmed the
syntax parses with the same local `terraform validate` container
before proposing it. `cloudflare_zero_trust_device_default_profile` is
the first resource in this project to use this pattern — the WAF
ruleset, DNS records, and mTLS hostname list (#6/#7/#11) still rely on
someone finding and re-running the manual command from this file if
their state ever needs rebuilding; worth retrofitting them the same
way at some point.

### 15. WAF rule inverted to default-deny

The original mTLS WAF rule matched an explicit allow-list of hostnames
(`http.host in {"argocd...", "books...", ...}`) — fails **open** for
anything published on the tunnel but left off that list, which is
exactly how `qnap` was briefly unprotected earlier in this project.
Rewrote the expression to match the whole zone instead
(`http.host wildcard "*.i3sec.com.au" or http.host eq "i3sec.com.au"`),
so a forgotten hostname now fails **closed** by default rather than
silently bypassing the client-cert check.

Did a full read-only discovery pass before touching anything (via the
same throwaway-pod/`terraform plan` pattern used throughout this
project) to check what the blast radius of "default-deny across the
whole zone" actually was, rather than assuming: confirmed the resource
is already `cloudflare_ruleset` (no deprecated `firewall_rule`/`filter`
migration needed), confirmed all 5 currently-tunneled hostnames already
carry mTLS associations (zero would newly fail closed), confirmed the
zone has no apex/`www` DNS record and no live ACME HTTP-01 dependency
(grepped every Ingress across all three cluster repos — the
`letsencrypt-*` `ClusterIssuer`s exist but nothing references them,
every Ingress uses `private-ca`), and confirmed no other custom
ruleset exists in the same phase to worry about ordering against. Net
result: today, this change has no functional blast radius at all — it
only closes the "next qnap" failure mode going forward.

First pass at the new expression (following the exact target given)
dropped the fingerprint-pinning clause that was already live
(`allowed_client_cert_fingerprints`, 5 pinned device certs) — caught
before applying and asked about explicitly, since silently narrowing
"any pinned device" to "any verified device from this CA" is a real
loosening riding along with the tightening, not something to assume.
Confirmed: keep both. Final expression combines zone-wide default-deny
with the existing fingerprint clause, unchanged from before.

### 16. obsidian + novnc, and a false alarm mid-apply

Second real test of the runbook (after #13's homeassistant) on an app
that isn't its own backend: obsidian's own hostname is a redirect-only
stub (its internal Ingress 302s unconditionally to novnc's websockify
UI, picking a token) — the actual traffic lands on `novnc.i3sec.com.au`.
Both hostnames had to be added to `tunneled_hostnames` together, or the
redirect target would be a dead public link. Otherwise routine: no
forward-auth of any kind on either (same as homeassistant, #13) — access
is the zone-wide mTLS gate alone, nothing app-level.

One new wrinkle: this is the first `ingress-nginx`-fronted websocket app
in the cluster (homeassistant/n8n's websockets are both Traefik-side,
which needed no extra annotation). `ingress-nginx` proxies websockets
fine with no special config, but its default 60s `proxy-read`/
`proxy-send-timeout` would silently drop an idle noVNC session
mid-session — bumped both to 3600s on `novnc-public-ingress.yml`, not
scientifically tuned, just long enough that a normal remote-desktop
session won't get cut off.

**False alarm, not a bug**: hit the Cloudflare WAF "you have been
blocked" page testing the new hostname right after pushing, before
double-checking the apply had actually finished. Re-ran a read-only
`terraform plan`/`state show` afterward (throwaway diagnostic pod, same
pattern as #15) against the live API and confirmed both hostnames were
correctly present in
`cloudflare_certificate_authorities_hostname_associations.mtls_hosts` —
`0 to add` on the plan, config was correct. The block was real but
transient: requests hit the zone-wide default-deny rule (#15) in the
narrow window where the tunnel/DNS resources for a new hostname can
land slightly before the mTLS hostname-association resource does within
the same `apply`, and/or Safari's documented per-hostname client-cert
caching (see `dns-conf`'s split-horizon fix notes) kept reusing a
"sent no certificate" decision from that first failed attempt. Fixed
itself on retry after clearing Safari's site data for the domain. Worth
remembering for the next hostname addition: **don't test the very
first request within the same minute as the merge** — or if you do and
hit a block, verify server-side state directly before assuming
something's actually wrong.

Also caught and fixed while investigating: `variables.tf`'s
`allowed_client_cert_fingerprints` description said "Empty = accept any
cert... (current behavior)" — misleading, since this deployment has
always sealed 5 real fingerprints via `cloudflare-tf-secrets`, so empty
has never actually been the live behavior. Comment fixed to stop
implying otherwise.

### 17. obsidian.i3sec.com.au removed (2026-07-19)

The redirect-only pairing from #16 didn't last a full day past this
doc's own advice about testing too early — obsidian itself was replaced
entirely with the official headless Obsidian Sync client the very next
day (day2-services `apps/obsidian`), which has no ingress, no listening
port, and nothing to redirect from anymore. Removed `obsidian.i3sec.com.au`
from `tunneled_hostnames`; `novnc.i3sec.com.au` stays, since it's still
tunneled for the unrelated `mac` target — #16's own point about checking
whether a hostname is *actually* that app's own backend before assuming
it can be removed alongside a sibling applies here too, just in the
opposite direction.

### 18. WARP route extended to the UniFi Dream Machine (2026-08-16)

Found while auditing pinode-01's network config against k8smaster's:
there was no off-LAN path to the UniFi console at all - not on the
public tunnel (never added), and not on the existing WARP route (only
covered k8smaster's `/32`). Extended `warp.tf`'s existing WARP setup
with a second route/include entry for `192.168.2.1` (new
`unifi_udm_lan_ip` variable, defaults to that address) rather than
either alternative: a public tunneled hostname would put router admin
on the open internet (meaningfully bigger attack surface than a
WARP-only route, even with the zone's mTLS WAF rule in front of it);
a second, separate WARP route/device-profile/enrollment app would work
but there's no reason to duplicate that plumbing for what's still just
a couple of trusted LAN IPs. Once enrolled in WARP, `https://192.168.2.1`
is reachable off-LAN, same pattern as `ssh 192.168.2.10` already was.

## What's true now

One variable (`tunneled_hostnames` in `variables.tf`) drives four
Terraform resources:

1. `cloudflare_zero_trust_tunnel_cloudflared_config` — tunnel routing
2. `cloudflare_dns_record` — the public DNS entry
3. `cloudflare_ruleset` (WAF) — mTLS enforcement (cert must be
   presented, verified, non-revoked, and optionally fingerprint-pinned)
4. `cloudflare_certificate_authorities_hostname_associations` — makes
   Cloudflare's edge actually request a cert for that hostname at all

Adding a hostname to that one map, for anything that's a standard
k8s-hosted app behind `ingress-nginx`, now genuinely produces all four
effects from one line. See the README's runbook for the full procedure,
including the nginx-specific gotchas from #12 above that the next app
with its own login page will probably also hit.

## Lessons for next time

- **This cluster's default `emptyDir` doesn't support POSIX file
  locking** (NFS-backed, `local_lock=none`). Anything that needs local
  file locks (Terraform state operations, SQLite, similar) needs
  `medium: Memory`.
- **Argo CD's git polling can lag noticeably.** When testing a fix that
  needs to land *now*, force it: hard-refresh the Application, and if
  that alone doesn't trigger a new sync (true for Sync-hook resources,
  which don't participate in normal drift detection), patch
  `.operation.sync` directly with the target revision.
- **Cloudflare's dashboard wizards routinely do more than one thing
  atomically.** Before assuming a single Terraform resource replicates a
  dashboard workflow, check whether the wizard secretly also touches DNS,
  a separate TLS/cert setting, an Access Application, etc. This project
  hit three separate "the dashboard did this for you" surprises (DNS
  records, the mTLS hostname list, and — as a red herring — a Cloudflare
  Access Application from an unrelated older project).
- **Check API token permissions for every Cloudflare API surface the
  project touches, up front**, not one `Authentication error` at a time.
- **nginx's `auth_request` and Traefik's `forwardAuth` are not
  drop-in-compatible** for an existing auth service. `auth_request` only
  accepts `2xx`/`401`/`403`; anything else (including a `302`, which
  Traefik handles fine) is an internal error. If porting an existing
  Traefik-based forward-auth setup to also work behind `ingress-nginx`,
  expect to need changes on the auth service's side, not just ingress
  annotations.
- **Overlapping regex + prefix paths on the same nginx Ingress host are
  dangerous.** nginx's location matching prefers a matching regex
  location over a plain prefix location regardless of which is more
  specific. Any auth-required catch-all regex needs to explicitly
  exclude sibling paths (like a login page) that must not go through the
  same auth check.
- **`terraform import` is required, every time, for anything the
  dashboard created before Terraform existed.** Check for pre-existing
  resources (rulesets, DNS records, hostname lists) before writing
  "create" logic, or the first `apply` will fail with a conflict.
- **Never run verbose HTTP debugging (`curl -v`) with real
  `Authorization` headers present** — it echoes the header value into
  output that may get logged or persisted.

## 2026-08-21 — known bugs found while adding an mTLS client cert

Two real issues surfaced adding a client cert to the allow-list; both
still want a proper fix:

1. **Sync-hook race.** `cloudflare-tf-job.yml` is an `argocd.argoproj.io/
   hook: Sync` job that reads the fingerprint list from the
   `cloudflare-tf-secrets` Secret. On a sync that CHANGES that secret, the
   hook can start before the sealed-secrets controller has decrypted the
   updated SealedSecret into the Secret, so terraform applies the OLD
   values and the change silently doesn't take effect. Worked around this
   time by running a manual (non-hook) copy of the job AFTER confirming the
   live Secret already held the new fingerprints. Proper fix options: an
   initContainer that waits until the Secret matches expected content, or
   an ArgoCD sync-wave so the SealedSecret reconciles before the hook runs.

2. **Manual re-run footgun.** The hook Job references the terraform source
   ConfigMap by its kustomize-hashed name (e.g.
   `cloudflare-tf-config-mb4bkd8h8t`). A hand-copied
   `kubectl apply -f cloudflare-tf-job.yml` uses the un-hashed name
   `cloudflare-tf-config`, which does not exist, so the pod hangs in
   ContainerCreating on FailedMount. To run the apply by hand, point it at
   the live hashed ConfigMap name (`kubectl get cm -n infra`).

Separately: **`bretts-mac` client cert (`d948fd9f…`) exists at Cloudflare
but its fingerprint was never added to the allow-list** — so that Mac is
blocked off-LAN despite having a valid cert. Half-finished from whenever it
was generated. Add its fingerprint via the runbook to complete it.
