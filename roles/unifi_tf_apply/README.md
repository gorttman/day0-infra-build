# unifi-tf

Manages the UniFi Dream Machine's config as Terraform, applied
in-cluster by an Argo CD Sync-hook Job — the same pattern
`apps/cloudflare-tf` uses, applied to the household network instead of
the Cloudflare edge. Scope is "everything that can be" managed as code:
networks/VLANs, WLANs, per-device radio/physical settings, firewall,
port forwards, static routes, static DHCP reservations, user groups.

**Status (2026-08-05):** real resources exist on the live gateway now
across every resource type in this app — all through throwaway
`kubectl`-created Jobs against the real backend, **not** through the
GitOps path (`unifi-tf-app.yml` is still not registered in
`apps/kustomization.yml`, nothing here is Argo CD-managed yet):

- **Applied for real**: `unifi_device.uap_shed` (canary — 3 low-stakes
  IoT clients, zero detectable disruption), then
  `in_wall_bedroom`/`in_wall_office`/`in_wall_bar`/`in_wall_lounge`
  together (that batch caused real, visible client roaming — see
  HISTORY.md #11). Then, once dry-run verified clean, all of
  `network.tf` (2 networks), `wlan.tf` (`ARDA_HOME`),
  `security-settings.tf` (IPS), and 30 of `clients.tf`'s clients —
  applied together as one explicitly `-target`-scoped batch specifically
  to keep the 3 held-back devices out of the blast radius (HISTORY.md
  #17). `Apply complete! Resources: 39 imported, 0 added, 35 changed, 0
  destroyed.`
- **Still NOT applied**: `switch_mainnet`, `switch_picluster`,
  `gateway` — deliberately held back, different risk class (HISTORY.md
  #10/#11), now backed by `http_max_retries` (HISTORY.md #15) but
  device-side risk to whatever's plugged into them is unchanged. 4 of
  39 clients still genuinely need the user's naming input
  (HISTORY.md #16). `firewall.tf`/`port-forward.tf` are intentionally
  empty, confirmed live multiple times.
- Every file above passes a combined dry-run together (`terraform
  plan` against the real backend, real state, zero `apply`) with only
  the two expected/benign diff patterns: synthetic create-time flags
  (`allow_existing`, `forget_on_destroy`, etc.) and same-plan resource
  references not yet resolved (`network_id`/`tx_power`-style "known
  after apply", which self-resolves once the referenced resource is
  actually applied for real).

Next real step: your call on when (and whether) to wire the rest in
for real, given the roaming blip from the last batch.

## Prerequisite: the control path must be wired, not WLAN

Both cluster nodes (`k8smaster`, `pinode-01` — the only two places the
Sync-hook Job can land) used to reach the UDM's own API over `wlan0`,
not their wired NICs, purely because `wlan0` happens to sit directly on
the same subnet as the gateway's management address. That's a real
risk specific to this app: a WLAN-disrupting apply (a radio change, the
WLAN resource itself) could cut the very control path being used to
manage it, mid-apply, with no visibility to recover. Fixed
(2026-08-04) with a `/32` host route on both nodes — see HISTORY.md
#10 for the full story, and `day0-infra-build`'s
`unifi-tf-backend-route` branch for the codified version. Verify this
is still in place (`ip route get 192.168.2.1` should show a wired
device, not `wlan0`) before trusting any future apply here.

## Control-path risk map, and http_max_retries

Two distinct risks worth separating clearly: whether *a device being
changed* briefly bounces (normal, expected, unavoidable — a radio
restart, a port flap) versus whether *our own request* gets caught in
that bounce because its own network path happens to route through the
device being changed. The first is fine. The second is what actually
matters, confirmed via real `uplink` topology data, not assumed:

- **Networks, WLANs, AP radios, firewall/security-settings/clients** —
  no risk. The wired control path never routes through any of these.
- **`Switch-PiCluster`** — real risk (the wired path runs through it),
  but WLAN is a genuine, confirmed-independent bypass (it reaches
  `Switch-MainNet` directly, never touching `Switch-PiCluster`).
- **`Switch-MainNet`** — real risk, and no alternate physical path
  exists — both the wired control route and any WLAN path converge
  through it before reaching the Gateway. True chokepoint.
- **`Gateway`** — it's the destination itself, not a hop; whether a
  radio-only update on a combo AP+gateway device stays scoped to just
  the radio subsystem is unconfirmed (inference, not tested).

For the chokepoint case (`Switch-MainNet`, and as a backstop for
`Switch-PiCluster` too): `versions.tf`'s provider block sets
`http_max_retries = 15` — the provider's own built-in resilience
(confirmed via its actual source, not just docs: retries
`GET`/`HEAD`/`PUT`/`DELETE`/`OPTIONS` — device updates are `PUT` — on
network/connection errors, 5xx, 429, or HTML-instead-of-JSON, linear
backoff `500ms × attempt`). **Tested for real** (HISTORY.md #15): blocked
the UDM's address on both nodes via a temporary blackhole route,
launched an apply directly into the outage, restored connectivity
after ~10s, and watched it complete cleanly with zero errors. Real
finding: total recovery took **140 seconds**, not the 10-15s a naive
reading of "500ms backoff" suggests — the first connection attempt,
made mid-outage, has to exhaust its own OS-level timeout (blackholed
connections don't fail fast) before the provider's retry logic even
gets a chance to see a definitive error. **Important: this 140s figure is a worst case, not routine
overhead** — it only happens if a request is unlucky enough to be
in-flight at the exact moment a device's own reprovisioning starts.
Most applies against `Switch-MainNet` won't hit this at all; the
device isn't bouncing during a random API call most of the time. Net
effect for the rare unlucky-timing case: the apply self-heals
completely, no manual intervention, no ambiguous state — it just may
take a couple of minutes longer, not seconds. `unifi-tf-job.yml`'s
`activeDeadlineSeconds: 600` already
covers this with room to spare.

HISTORY.md #15 has the full reasoning path, not just this summary —
worth reading if this ever needs revisiting, including the
localhost-on-the-UDM alternative that was correctly reasoned through
and deliberately set aside (real cost: state backend is remote
Postgres, this UDM model has no drive bay, firmware updates wipe local
installs) in favor of `http_max_retries` instead.

## Why this deviates from cloudflare-tf's risk profile

`cloudflare-tf` manages Cloudflare's edge — worst case on a bad apply is
a routing/WAF misconfiguration affecting public access to self-hosted
services. This app manages the live gateway and access points for the
whole house: a bad apply on a network or WLAN resource can drop Wi-Fi
for every device, and UniFi provisioning changes cause a real AP/gateway
reprovision (a brief but real outage), not just a config reload.

That's why this app is built up in stages rather than landing "the whole
UniFi config as Terraform" in one PR:

1. Inventory the Dream Machine's actual current config via its API —
   every resource written here has to match what's *actually live*
   first, never authored from guesswork.
2. Scaffold with zero resources, confirm the Job runs `init`/`plan`/
   `apply` cleanly end to end.
3. One resource type at a time — networks first (everything else refers
   to them), then WLANs, then per-device radio settings, then firewall,
   then port forwards/static routes, then static clients — each
   `terraform import`ed against the existing object, never created
   fresh, and each its own commit/PR so a bad stage is easy to isolate
   and revert.

Do the first-ever apply of each new resource type at a low-usage time —
even a no-op-intended change can trigger a brief AP reprovision.

## Credential — sealed (2026-08-04)

Network application version confirmed at 10.5.67 (the version that
matters for API-key eligibility — not the UDM/UniFi-OS version, which
is a separate number; see HISTORY.md #3), well above the 9.0.108
minimum. API key created from **Integrations → Create New API Key**
inside the local Network application UI (not Site Manager — see
HISTORY.md #3 for why that distinction matters), no expiry set (see
HISTORY.md #3 on rotation). Sealed into `unifi-tf-secrets` alongside
`TF_BACKEND_PG_CONN_STR`, same `kubeseal --raw` pattern as
`cloudflare-tf-secrets`.

### Runbook: rotating the API key later

1. Integrations page → revoke the old key, create a new one, copy it
   immediately (shown once).
2. Seal just that field, leaving `TF_BACKEND_PG_CONN_STR` untouched:
   ```bash
   echo -n '<new-key>' \
     | sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubeseal --raw \
         --scope strict --namespace infra --name unifi-tf-secrets
   ```
3. Paste the output into `unifi-tf-sealedsecret.yml`, replacing only the
   `TF_VAR_unifi_api_key` value.
4. Commit and push — lands on `main` with `automated: {selfHeal: true}`,
   so it applies on merge like everything else here.

## Provider: `filipowm/unifi`, not `paultyng/unifi`

`paultyng/unifi` is the better-known UniFi Terraform provider, but its
docs cap out at controller v6.x support and password-only auth.
`filipowm/unifi` is an actively maintained fork with explicit UDM/UDM-Pro/UCG
support, API-key auth, and much broader resource coverage — networks,
WLANs, both the legacy (`firewall_group`/`firewall_rule`) and newer
zone-based (`firewall_zone`/`firewall_zone_policy`) firewall models,
port forwards, static routes, DNS records, static clients (`unifi_user`),
user groups, RADIUS, and per-device settings including radios
(`unifi_device` — channel, TX power, channel width, minimum-RSSI/roaming
threshold, LED behavior).

API-key auth is preferred for the same reason `cloudflare-tf` uses a
scoped API token rather than full account credentials: it's revocable
and doesn't require storing a real admin password.

## State backend: shared Postgres

Same pattern as `cloudflare_tf`: a dedicated `unifi_tf`
database/role on the shared Postgres instance
(`day2-services/apps/postgres`), onboarded via that app's automated
init-Job path (the README there recommends this over manual `kubectl
exec` for any new database going forward). `versions.tf` declares
`backend "pg" {}` with no `conn_str` — partial config on purpose, so the
connection string never lands in git; supplied at `terraform init` time
via `-backend-config`, reading `TF_BACKEND_PG_CONN_STR` from
`unifi-tf-secrets`.

## Inventory (2026-08-04)

Read-only pass against the live console — every call was HTTP `GET`
against either the official Integration API
(`/proxy/network/integration/v1/sites/{siteId}/...`, `X-API-KEY` auth)
or the legacy REST API (`/proxy/network/api/s/default/rest/...`, which
turned out to accept the same API key — no separate username/password
session needed after all). Nothing was created, modified, or deleted;
`GET` is inherently non-mutating for both APIs. Findings:

- **Firewall model**: `firewall/zones` → `"Zone Based Firewall is not
  configured"` — this console runs the **legacy** model. Both
  `firewallgroup` and `firewallrule`/`portforward` are currently
  **empty** — a clean slate for tasks 9/10, nothing existing to
  reverse-engineer.
- **Networks (2 user-facing, plus system WAN)**: `Default` (VLAN 1,
  system default) and `Cluster-Backend` (VLAN 10 — the k3s cluster's
  network). Legacy `networkconf` also lists `Internet 1`
  (`purpose: wan`) — system-managed, not a `unifi_network` candidate.
- **WLANs (1)**: `ARDA_HOME`, WPA2-Personal, dual-band (2.4 + 5 GHz).
- **Devices (8)**: 2 switches (`Switch-MainNet`, `Switch-PiCluster`,
  both US 8 PoE 150W) and 6 APs (`UAP - Shed` / AC Pro,
  `In-Wall-Office` / AC IW, `In-Wall-Bedroom` / IW HD, `In-Wall Lounge`
  / U6 IW, `In-Wall-Bar` / U6 IW). No AP is literally named "study" —
  `In-Wall-Office` is the likely candidate for the roaming problem's
  "study AP," not confirmed. The Integration API's per-device `GET`
  only returns *current observed* radio state (channel/width/frequency),
  not the full configurable field set (`tx_power_mode`, `min_rssi`,
  etc.) — task 8's actual read/import will need the legacy REST API for
  those, same as it turned out firewall/port-forward did.
- **31 live clients** currently connected — a different, larger set
  than task 11's static/DHCP-reservation `unifi_user` entries, not yet
  pulled separately.

## Scope

**Managed**, in rollout order:

- **Networks/VLANs** (`unifi_network`) — base layer, everything else
  refers to these.
- **WLANs/SSIDs** (`unifi_wlan`).
- **Per-device radio/physical settings** (`unifi_device`) on
  already-adopted devices — channel, TX power, channel width,
  minimum-RSSI/roaming thresholds, LED behavior. Directly relevant to
  the sticky-AP roaming problem (devices in the study staying connected
  to the bar AP instead of the nearer one) — minimum-RSSI kick and
  per-radio tuning live here.
- **Firewall** — legacy model (`firewall_group`/`firewall_rule`),
  confirmed by the inventory pass (see below), not zone-based.
- **Port forwards** (`unifi_port_forward`) and **static routes**
  (`unifi_static_route`).
- **Static client/DHCP reservations** (`unifi_user`) and **user
  groups** (`unifi_user_group`) — including each client's `name`,
  `note`, `fixed_ip`, `network_id`, `user_group_id`, `blocked` state,
  and `dev_id_override` (see "On client icons" below).
- Anything else inventory turns up as actually configured (DNS records,
  RADIUS profile).

**Not managed**, deliberately:

- True first-time physical device **adoption** — bringing a brand-new
  AP/switch onto the controller for the first time. Distinct from
  managing settings on an already-adopted device (which *is* in scope
  above); adoption stays a manual UI step.
- Any `setting_*` singleton still sitting at UniFi's default — importing
  a default just because the resource exists adds risk (one bad edit is
  a whole-site setting) with no benefit. Add individually later only if
  one is actually hand-tuned.

**On infrastructure device icons** (APs/switches/gateway): checked —
there's no icon/display-type attribute anywhere in the `filipowm/unifi`
provider's `unifi_device` resource. Those pictograms are derived
automatically from the hardware model/shortname the device reports on
adoption, not a stored setting, so there's nothing to manage there.

**On client icons** (end-user devices — phones, laptops, IoT): different
answer. UniFi classifies every client via automatic fingerprinting (MAC
OUI, DHCP fingerprint, mDNS, etc.) into a `dev_id`/`dev_cat`/`dev_family`
combination that decides which icon renders — confirmed live via the
legacy REST API's `rest/user` endpoint, which returns those fields per
client alongside a `fingerprint_engine_version`/`confidence` score. The
icon itself still isn't a stored, freestanding setting — but the
classification *can* be overridden: `unifi_user`'s `dev_id_override`
attribute ("Override the device fingerprint") is real and Terraform-
manageable, which changes the icon as a side effect of overriding the
fingerprint match. Confirmed with real live examples, not just theory:
18 of `clients.tf`'s 30 clients already have a real `dev_id_override`
set live — captured as existing state, not invented (see HISTORY.md
#16 — scope was corrected twice here: first from "only 6 clients have
enough live data" to "25 of 39 already have a real name," then again
to "10 more have a usable `hostname` where `name` is empty," leaving
only 4 clients that genuinely have neither). What's still unresolved:
what numeric `dev_id` values actually *mean* (no public Ubiquiti
lookup table found, see HISTORY.md #7) — fine for preserving existing
overrides, blocking for choosing new icons on the 4 real remaining
clients (or the ~9 recently-active ones with a name but no icon at
all). User's explicit call (2026-08-04): "not sure, let's cover it
when we get there."

## Security settings — a real exception to "don't manage defaults"

`security-settings.tf` (`unifi_setting_ips`) is genuinely NOT at
UniFi's default — IPS/threat prevention is actively enabled in
blocking mode (`ips_mode: "ips"`) with a real, curated 11-category
threat list, confirmed live via `get/setting` (`key=ips`). Exactly the
kind of hand-tuned setting the "don't manage default singletons" rule
in Scope above was always meant to include, not exclude. `utm_token` (a
real secret-looking value in the live data) has no attribute anywhere
in this provider's schema — almost certainly Ubiquiti-cloud-issued and
system-managed, so nothing sensitive ends up in this file.

## Layout

- `unifi-tf-app.yml` — Argo CD `Application`. Not yet in
  `apps/kustomization.yml` (see Status above).
- `unifi-tf-job.yml` — Sync-hook `Job`, same `medium: Memory` `emptyDir`
  workaround as `cloudflare-tf` (this node's default `emptyDir` is
  NFS-backed and fails Terraform's state-lock `flock()`).
- `unifi-tf-sealedsecret.yml` — exists, sealed for real (API key +
  Postgres conn string). `wlan_arda_home_passphrase` is drafted as a
  variable but NOT yet resealed into this file — `wlan.tf` isn't
  applied for real yet, so there's nothing live depending on it.
- `kustomization.yml` — `configMapGenerator` with the hash suffix left
  enabled, same reasoning as `cloudflare-tf` (this ConfigMap feeds a
  Sync-hook Job, not a Deployment — the hash is what makes a
  content-only `.tf` edit visible to Argo CD's diff). Still only lists
  `versions.tf`/`variables.tf` — the rest of the resource files aren't
  wired into the real ConfigMap yet (see Status above).
- `terraform/` — `versions.tf`, `variables.tf`, `network.tf`,
  `wlan.tf`, `device.tf`, `firewall.tf`, `port-forward.tf`,
  `security-settings.tf`, `clients.tf` all exist and are dry-run
  verified. See Status above for which are also applied for real.

See `HISTORY.md` for the build log as each stage lands.
