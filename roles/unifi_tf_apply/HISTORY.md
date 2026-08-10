# unifi-tf: build history, mistakes, and fixes

Full narrative of building this app, for institutional memory. Same
convention as `cloudflare-tf/HISTORY.md` — if something looks weird in
the code, the answer is probably in here.

## The goal

Bring the UniFi Dream Machine's config — networks/VLANs, WLANs,
per-device radio settings, firewall, port forwards, static routes,
static DHCP reservations — under Terraform, run in-cluster by an Argo CD
Sync-hook Job, same architecture as `cloudflare-tf`. Motivating problem:
a sticky-AP/roaming issue where devices in the study stay connected to
the bar AP in another room instead of the nearer study AP — likely
fixable via WLAN minimum-RSSI/band-steering settings and/or per-AP radio
tuning, both in scope for this app.

## 1. Provider choice: `filipowm/unifi` over `paultyng/unifi` (2026-08-04)

Researched both before writing anything. `paultyng/unifi` is the
better-known provider (it's what most tutorials reference), but its own
docs say it caps out at controller v6.x support with password-only auth.
`filipowm/unifi` is an actively maintained fork with explicit
UDM/UDM-Pro/UCG support, API-key auth (needs controller ≥ 9.0.108), and
much broader resource coverage. Confirmed via the provider's GitHub docs
directly (`raw.githubusercontent.com/filipowm/terraform-provider-unifi`)
since the Terraform Registry's own docs page is JS-rendered and doesn't
return real content to a headless fetch.

## 2. Scope revision: device settings went from "excluded" to "in scope" (2026-08-04)

First draft of the plan excluded `unifi_device` entirely (physical
AP/switch management) on the reasoning that hardware-state changes carry
disproportionate disruption risk for a homelab. Revised same day once
the actual motivating problem (sticky-AP roaming) came up — per-AP
radio/TX-power/minimum-RSSI tuning needs `unifi_device`, so excluding it
entirely would have excluded the actual fix. Landed on a narrower line
instead: **settings** on an already-adopted device are in scope,
first-time device **adoption** stays manual. Those are genuinely
different operations with different risk profiles — adoption is a
one-time hardware-pairing action, settings changes on an adopted device
are what this whole app is for.

## 3. Finding the API key: wrong guesses, then the real location (2026-08-04)

Two wrong menu-path guesses before landing on the right one, worth
recording so nobody re-treads this: guessed "Settings → System" for the
firmware version (wrong - firmware/UDM version and the Network
application version are two different numbers shown in different
places, and the one that actually matters for API-key auth eligibility
is the **Network application version**, not the UDM/UniFi-OS version -
confirmed 10.5.67 vs 9.0.108 minimum). Then guessed "Control Plane →
Admins & Users → Create API Key" for the key itself - also wrong, and
also based on stale/generic documentation, not this specific version.

The real location, confirmed live: **Integrations** page inside the
local UniFi Network application itself → Create New API Key. This is
deliberately the **Network Application API key**, not a **Site Manager
API key** (created separately at unifi.ui.com, routes through
Ubiquiti's cloud) - the two are different credential systems for
different connectivity models, and only the Network Application key
works for a direct local-IP integration like this one. Created with no
expiry (see README.md's Secrets section) since there's no rotation
automation in this pipeline yet - an automated rotation integration is
a real future idea, just not built as part of this initial setup.

## 4. Device icons: confirmed not manageable (2026-08-04)

Asked whether the UniFi UI's per-device-type icons (AP, switch, gateway
pictograms) could be set via Terraform. Checked the `unifi_device`
resource's full attribute list in the provider docs — no icon or
display-type field anywhere. These are derived client-side from the
hardware model/shortname the device reports on adoption, not a stored
API setting. Nothing to do here, just worth recording so the question
doesn't get re-asked and re-researched later.

## 5. Stage 2 verification hit a real snag - Argo CD parent/child sync (2026-08-04)

Merged both PRs (`unifi-tf-scaffold` and the Postgres `unifi_tf`
onboarding). First `unifi-tf-apply` run failed:
`pq: password authentication failed for user "unifi_tf"`. Root cause
wasn't the app - it was assuming a `kubectl patch ... refresh:hard` on
the **parent** Argo CD Application (`day2-services`) would cascade to
its **child** app (`postgres`). It doesn't: each child app is its own
independent `Application` object with its own `selfHeal`-driven poll
cycle against its own git path, entirely decoupled from the parent
except for the parent creating/updating the child's `Application`
resource itself. Since `postgres-app.yml` hadn't changed, refreshing
the parent had nothing to do, and `postgres` just hadn't hit its next
normal ~3-minute poll yet - so the `unifi_tf` role/database didn't
exist when Terraform tried to connect. Fixed by refreshing `postgres`
directly, then re-triggering `unifi-tf`'s own sync explicitly (Sync
hooks don't self-retry - `kubectl patch application ... operation.sync`
with the target revision). Second run succeeded cleanly: `No changes.
... Apply complete! Resources: 0 added, 0 changed, 0 destroyed.`
**Lesson for next time**: refresh the specific child app that actually
changed, not its umbrella parent.

## 6. Inventory pass - GET-only, confirmed live (2026-08-04)

Ran the actual inventory pass (README.md's "Inventory" section has the
full findings). Worth recording the process, not just the results:
every single call was explicitly `-X GET` against either the official
Integration API (`X-API-KEY` header) or the legacy REST API - confirmed
in advance that REST semantics make `GET` inherently non-mutating, and
verified after the fact that no `POST`/`PUT`/`DELETE` was ever issued.
One assumption from secondary docs turned out wrong in a helpful way:
the legacy REST API was expected to need cookie/session auth, not the
API key - it accepted the same `X-API-KEY` header fine, so tasks
9-11 won't need a separate username/password session after all.

## 7. Client icons: a real, different answer from device icons (2026-08-04)

Same question as #4, but for end-user clients (phones, laptops, IoT)
instead of infrastructure devices (APs/switches) - and a different
answer this time. Checked `unifi_user`'s full attribute list:
`dev_id_override` ("Override the device fingerprint") is real and
Terraform-manageable. Confirmed live via the legacy REST API's
`rest/user` endpoint, which returns `dev_id`/`dev_cat`/`dev_family`/
`fingerprint_engine_version`/`confidence` per client - UniFi
auto-classifies every client via fingerprinting (MAC OUI, DHCP
fingerprint, mDNS), and that classification is what picks the icon.
There's still no literal "icon" field to set directly, but overriding
the fingerprint via `dev_id_override` changes the icon as a side
effect. Added to task 11's in-scope list for any client that's
actually been hand-overridden this way - same "only manage what's
actually customized" principle applied to the `setting_*` singletons.

## 8. network.tf: a real dry-run-only workflow, and a wrong methodology corrected (2026-08-04)

Before letting the real Sync-hook Job anywhere near `terraform import`
against the live gateway, ran a throwaway, plan-only Job (own ConfigMap
+ Job, created directly with `kubectl`, never touching git/Argo CD,
deleted after) using the same `pg` backend and sealed secrets as the
real app - `terraform init` + `terraform plan`, no `apply` step at all,
so nothing could be written even if something went wrong. It caught two
real problems before they became live changes:

**Wrong import ID format.** First attempt used the IDs from the
Integration API's `networks` list (`id`/`external_id`, UUID-shaped) -
failed with `Cannot import non-existent remote object`. This provider
is built on the legacy REST API underneath, whose network ID is a
different, 24-char ObjectId (`_id` in that API) - completely different
namespace from the Integration API's ID, despite both nominally
identifying "the same" object. Switched to the provider's `name=`
import format instead (`id = "name=Default"`) - documented as a
supported alternative, sidesteps needing either ID, self-documenting.

**Wrong methodology for "safe to omit."** The working assumption going
in was: if a field has no documented default, or matches a documented
default, it's safe to leave undeclared - Terraform will treat it as
computed and adopt whatever's live, zero drift. The dry-run plan proved
this wrong on two counts:
- `ipv6_ra_enable` (live: `true`) - leaving it undeclared didn't adopt
  the live value, it planned to null it out.
- `ipv6_ra_valid_lifetime` - the docs state a default of `86400`, but
  this console's actual live value is `0`. Leaving it undeclared meant
  Terraform planned to push the *documented* default onto live state,
  overwriting the real value - the exact opposite of "safe."
- `dhcp_start`/`dhcp_stop` on `Cluster-Backend` (DHCP disabled there) -
  assumed these didn't matter since DHCP is off, but live still has
  them stored, just inactive. Omitting them planned to null them out.
  "Disabled" is not "unset" in UniFi's data model.

**Corrected approach for every remaining stage (WLANs, devices,
firewall, etc.)**: the dry-run plan output is the only real ground
truth for "does this field need to be declared" - not the provider
docs' stated defaults, not assumptions about `Computed` behavior. Every
field in `network.tf` was verified against an actual zero-diff plan
before being considered settled - final result: `Plan: 2 to import, 0
to add, 0 to change, 0 to destroy.` This same
create-a-throwaway-plan-only-Job-first workflow should be the default
for every future resource type in this app, not just networks.

## 9. wlan.tf: a secret in the inventory, and a deeper version of the same lesson (2026-08-04)

Pulled `ARDA_HOME`'s full config via legacy `rest/wlanconf` - it returns
the WPA passphrase in plaintext (`x_passphrase`). Never written to a
`.tf` file: added `wlan_arda_home_passphrase` as a sensitive Terraform
variable, same `TF_VAR_*`-from-sealed-secret treatment as the UniFi API
key itself. For the throwaway dry-run Job, used a second, separate
`kubectl`-created Secret (`unifi-tf-dryrun-secrets`, deleted after) to
supply it, rather than touching the real `unifi-tf-secrets` before it's
actually ready to be resealed with a new field for real.

`unifi_wlan`'s import syntax has no `name=` option (unlike
`unifi_network`) - raw legacy `_id` only, confirmed in the provider's
docs before attempting anything.

Also referenced `unifi_network.default.id` instead of hardcoding the
network's ID for `network_id` - both resources import in the same
plan/apply, so this is a real Terraform-level dependency, not a second
magic string that could silently drift from the first.

**The dry-run caught something more subtle than network.tf's lesson**:
this time the mismatch wasn't "docs vs. reality," it was "my own
reading of the raw legacy JSON vs. reality":
- `mac_filter_policy`: raw JSON said `"allow"`, but the provider's own
  post-import read reported `"deny"` - and since `mac_filter_enabled`
  is `false` on both sides, the field has zero live effect either way.
  Matched what the provider actually reports, not the JSON.
- `minimum_data_rate_2g_kbps`: raw JSON's `minrate_ng_enabled: true` /
  `minrate_ng_data_rate_kbps: 1000` looked like a real 1000kbps floor
  was active - but the WLAN's top-level `minrate_setting_preference:
  "auto"` overrides those per-band fields entirely. The provider's own
  refreshed value is `0` (disabled), not `1000`. Same class of mistake
  as `dhcp_start`/`dhcp_stop` staying set-but-inactive on a
  DHCP-disabled network - a legacy field can be present and non-null
  while functionally inert, and only the provider's own interpretation
  (not a raw field read) tells you which is true.

**Refined methodology, going forward**: don't just avoid trusting
provider-doc defaults (lesson #8) - avoid trusting your own reading of
raw API JSON too, whenever the live object has multiple interacting
fields (an enabled flag, a preference/mode field, and a value field
together). The dry-run plan's shown "current" value after
import/refresh is the only real ground truth for what a field's live,
*effective* state actually is. Final result: `Plan: 3 to import, 0 to
add, 0 to change, 0 to destroy.`

## 10. device.tf: a real port_override catch, and a routing prerequisite discovered (2026-08-04)

Pulled `stat/device` for all 8 devices. Radio config alone wasn't
enough - the first dry-run showed `Gateway` and `Switch-PiCluster` both
wanting to **remove** live `port_override` blocks that were never
captured (the inventory pass only looked at `radio_table`, not
`port_overrides`). `Switch-PiCluster`'s ports 3/7/8 carry
`Cluster-Backend` (native VLAN 10) to specific physical ports - almost
certainly the actual Pi cluster wiring (matches the fixed-IP static
clients on 192.168.1.x: `pinode-m`, `k8smaster-m`, `valinor-m`).
Applying the original draft would have reverted real switch-port VLAN
config, risking actual cluster connectivity, not just Wi-Fi. Added the
missing `port_override` blocks (only the attributes this provider
actually exposes - `speed`/`full_duplex`/`autoneg`/storm-control/port
security have no Terraform equivalent, dashboard-only), re-verified
clean.

`forget_on_destroy` defaults to `true` on this provider - meaning an
unmanaged `terraform destroy` or forced replacement could un-adopt real
hardware. Set `false` explicitly on every device, non-negotiable, no
exceptions.

**The "pending change" discussion.** Even with every radio field
matching live exactly, `tx_power` (irrelevant when `tx_power_mode !=
"custom"`, true for every radio here) always renders as `(known after
apply)`, dragging the whole `radio` block into "pending" in the plan -
a provider quirk, not a real mismatch. Confirmed this isn't a
permanent state: it's specific to importing into empty state (nothing
to compare `tx_power` against yet) - after one real apply, Terraform
records whatever the API returns as a concrete value, and subsequent
plans should resolve cleanly, same as network.tf/wlan.tf. Estimated a
10-30 second radio-restart window from general UniFi behavior, but
explicitly flagged that as an estimate, not a measurement - see #12 for
what actually happened.

**Discovered mid-discussion, not initially part of this stage**: both
`k8smaster` and `pinode-01` were reaching the UDM's own API
(`192.168.2.1`) over `wlan0`, not their wired NICs - confirmed via `ip
route get` on both, not assumed. Root cause: `wlan0` sits directly on
`192.168.2.0/24` while `end0`/`eth0` only have the on-link route to
`Cluster-Backend` (`192.168.1.0/27`) - the kernel prefers the more
specific, directly-connected interface. Real risk: a WLAN-disrupting
apply could cut the very control path used to manage it, mid-apply,
with no visibility to recover. Fixed live on both nodes via `nmcli
connection modify <conn> +ipv4.routes "192.168.2.1/32 192.168.1.1"` +
`nmcli device reapply` - a `/32` host route to just the UDM's own
address, not the whole subnet. Gateway IP (`192.168.1.1`) confirmed via
UniFi's own `ip_subnet` field convention (`<gateway-ip>/<prefix>`,
cross-checked against `Default`'s `192.168.2.1/24` which is verifiably
the real gateway), not guessed, then verified live with a ping first.
User's call: fix **both** nodes rather than pin the Job to one ("not a
fan of pinning too much") - correct, since Pod egress follows whichever
node's own routing table it lands on. Verified at three levels (host
curl, SSH'd curl, in-cluster throwaway Pod curl) and again later with a
forced-interface test (`curl --interface end0/eth0`) bypassing normal
route selection entirely - all succeeded. Codified into
`day0-infra-build` (`variables/play/day0_bootstrap.yml`'s new
`backend_vlan_routes`, wired into
`roles/prep_prerequisites/tasks/network.yml` via `routes4`) for the
next from-scratch rebuild, pushed as branch `unifi-tf-backend-route`,
not merged - deliberately did NOT re-run the full day0 bootstrap
playbook against live production nodes to apply this (it does far more
than networking), applied the live fix directly instead. Found along
the way: `pinode-01`'s wired connection is actually named `eth0`, not
`end0`/`backend-vlan` like the existing Ansible task assumes -
pre-existing inconsistency, documented inline, not fixed.

## 11. First real applies: a canary, then a real roaming blip (2026-08-04)

First-ever real `apply` against the live gateway (not a dry-run) -
`unifi_device.uap_shed`, chosen as a low-stakes canary (3 IoT clients:
two outdoor smart plugs, one Google Home). Used `terraform apply
-target=unifi_device.uap_shed` inside a throwaway `kubectl`-created Job
against the real backend, scoped to just that one resource - checked
the *targeted* plan first (still plan-only) before ever flipping to
apply, same discipline as every other stage. Result: `provisionedAt`
confirmed a real reprovision fired, but all 3 clients stayed connected
throughout with unchanged `connectedAt` timestamps - no detectable
disruption. Caveat stated plainly at the time: this isn't
packet-capture-grade measurement, a sub-second blip too brief to reset
a timestamp wouldn't show up here.

Proceeded to the 4 remaining pure APs (`In-Wall-Bedroom`,
`In-Wall-Office`, `In-Wall-Bar`, `In-Wall Lounge`) as one batch, same
targeted-plan-then-apply discipline. **This one was not a non-event.**
Baseline vs. after:
- `In-Wall-Office`: 1 → 4 clients
- `In-Wall-Bedroom`: 2 → 0
- `In-Wall Lounge`: 10 → 2
- `In-Wall-Bar`: 5 → 0
- `Gateway` (not even touched by this apply): 0 baseline → **17**
  clients

Total client count stayed intact (33 vs. ~31 original baseline -
nothing dropped off the network permanently), but real, visible
roaming occurred, and most displaced clients landed on the Gateway's
own radio rather than a nearby AP - directly reproducing the exact
"family-room TV connects to the Gateway from 30cm away from an in-wall
AP" behavior mentioned earlier as an example of "devices doing weird
stuff in general." Not a coincidence; very likely the same underlying
roaming-decision problem this whole app was motivated by.

**Why the canary didn't predict this**: static IoT plugs (the shed's 3
clients) don't actively scan/roam the way phones, laptops, and smart
TVs do. A single low-traffic AP with passive clients is a fundamentally
different test than APs serving actively-roaming devices. Lesson for
any future canary-style test: match the canary's client mix to what
you're actually trying to de-risk, not just "pick the quietest one."

Deliberately held back the remaining 3 devices (`Switch-MainNet`,
`Switch-PiCluster`, `Gateway`) after this - different, higher-stakes
risk class (`Switch-PiCluster` carries real Pi cluster wiring; `Gateway`
is the UDM itself), and the roaming blip from this batch was reason
enough to pause rather than push further the same night.

## 12. security-settings.tf: IPS is a real, non-default exception (2026-08-04)

Checked `get/setting` (legacy API) for DPI and IPS. DPI itself is off
(`enabled: false`), but device fingerprinting is on (`true`) -
confirms the mechanism behind #7's client-icon finding. IPS is a
different story entirely: **actively enabled in blocking mode**
(`ips_mode: "ips"`) with a real, curated 11-category threat list
(`botcc`, `dshield`, `emerging-exploit`, etc.) - genuinely hand-tuned,
not a default sitting untouched. A real, deliberate exception to the
"don't manage default-valued singletons" rule in README.md's Scope -
that rule was always about avoiding *risk without benefit*, and this is
exactly the opposite case.

`utm_token` (a real secret-looking value in the live legacy JSON) has
no attribute anywhere in `unifi_setting_ips`'s complete schema -
checked the full list, not a curated summary, same discipline as every
other resource here. Almost certainly a Ubiquiti-cloud-issued
credential for signature updates, system-managed and not user-settable
- nothing sensitive ends up in `security-settings.tf` as a result.

Import ID: no "Import" section documented. First guess (`"default"`
alone) failed, but with a genuinely helpful error - `"ID does not
contain site part. Format should be 'site:id'"` - so it needed the
same `site:id` format network/wlan's docs mentioned for cross-site
imports, just apparently required here even for the default site.
Fixed with `"default:<the ips setting's own legacy _id>"`, verified
clean on the very next try: zero diff on the resource itself.

## 13. clients.tf: two real fields almost silently destroyed (2026-08-04)

First draft covered only `mac`/`name`/`fixed_ip`/`network_id` for the 6
clients with genuinely active (`use_fixedip: true`) reservations. The
dry-run caught real, live values that draft never captured at all:
- `local_dns_record` - 5 of the 6 clients already have a real, working
  local DNS name (e.g. `googlehome-bar.i3sec.com.au`).
- `dev_id_override` - 5 of the 6 already have a real icon override set
  (`2028` for the Google Home devices, `4133` for the Linux hosts).

Leaving either undeclared would have **wiped both on apply** - not a
cosmetic diff like earlier stages, an actual destructive one, caught
only because the "verify every field via dry-run, don't trust your own
field selection" discipline was applied here too. Fixed by pulling the
*complete* raw record for each client (not just the subset of fields
used to write the first draft) and declaring both explicitly with their
real live values - these are existing state being preserved, not new
choices invented here. Re-verified clean afterward.

Also found and deliberately did NOT act on: `k8smaster`'s record has a
"fixed AP" pin defined but disabled (`fixed_ap_mac` → `In-Wall-Office`,
`fixed_ap_enabled: false`) - someone set this up before, presumably as
an earlier attempt at the same roaming problem. Not in the
`unifi_user` schema fetched for this file - worth checking again if a
"pin a client to its nearest AP" approach is ever revisited.

**Scope boundary held deliberately**: user's actual ask is all 76
known clients eventually - cleaned-up names for every one, plus a
`dev_id_override` for each. This file only covers the 6 where
`fixed_ip` is genuinely active live - 13 more have `fixed_ip` present
but `use_fixedip: false` (including `k8smaster-m`/`pinode-m`/
`valinor-m`, which get their addresses from their own static
NetworkManager config instead, see #10 - declaring `fixed_ip` for
those would create a reservation that doesn't currently exist), and
~57 more have only a name or nothing at all. 2 of the 6 genuinely-active
clients have no live name at all (`name` is required) - not drafted,
noted by MAC/IP instead of inventing one. None of the remaining ~70
clients' names or icons were touched or guessed at - that's the user's
call, explicitly deferred ("not sure, let's cover it when we get
there"), not something to decide overnight.

## 14. Client scope was wrong - "76" was every client ever, not what's real (2026-08-05)

User checked the actual UniFi UI the next morning: it shows 38 clients,
not 76. Real discrepancy, checked properly rather than dismissed - `76`
was the full result of `legacy rest/user`, which returns **every
client the controller has ever recorded**, including entries with
`first_seen` timestamps from 2021/2023 - almost certainly devices that
don't exist on the network anymore (old phones, long-gone guests,
etc.). That's not what the UI's default Clients view shows.

Checked what actually matches: clients with `last_seen` within 30 days
= 39 (currently-connected right now = 33; within 7 days = 31; full
history = 76). 39 is close enough to the UI's 38 that this is the real
number - the 1-client gap is just real-time activity in the hours
between last night's session and this check, not a method mismatch.

User's call, immediately and firmly: "if it hasn't been connected in
the last 30 days then its dead dead dead." Scope corrected to the 39
recently-active clients (33 remaining beyond the 6 already in
`clients.tf`), not the full 76-deep history. Useful general lesson:
"how many X does the live system have" needs the same rigor as every
other inventory question here - a raw API count and what a human
actually sees in the UI can differ by 2x if the API returns unfiltered
historical data by default.

## 15. The `Switch-MainNet` control-path problem: the full reasoning, the dead end, and the real fix (2026-08-05)

Full narrative, not just the conclusion, because the reasoning path
here is worth as much as the destination - several dead ends were
correct reasoning that just didn't pay off, not wasted effort.

### The starting problem

After the wired-route fix (#10) and the 4-AP batch (#11), three
devices were deliberately held back: `Switch-MainNet`,
`Switch-PiCluster`, `Gateway`. User asked, reasonably: can we build
something smarter than "just be careful" - specifically, can Terraform
requests fail over to WiFi if the wired network itself is what's being
changed, "or vice versa"?

### Mapping the real topology, not guessing at it

Pulled actual `uplink` device-ID chains from the API rather than
assuming symmetry between wired and wireless paths:

```
k8smaster (end0, wired)  → Switch-PiCluster → In-Wall-Office (wired passthrough) → Switch-MainNet → Gateway
k8smaster (wlan0)        → [whichever AP]                                       → Switch-MainNet → Gateway
```

This produced a real, useful, asymmetric answer: WLAN genuinely
bypasses `Switch-PiCluster` (confirmed - `In-Wall-Bar`'s uplink is
`Switch-MainNet` directly, never touching `Switch-PiCluster`), so a
WLAN-fallback procedure was proposed and would have worked for that
one device. But `Switch-MainNet` is a true chokepoint - **every**
path, wired or wireless, converges through it before reaching the
Gateway. No routing trick exists that avoids it. Also discovered along
the way: `Switch-PiCluster`'s "uplink" is `In-Wall-Office`, not a
direct switch-to-switch link - that AP has wired passthrough ports and
is physically an intermediate hop in the cluster's own wired chain,
not just a WiFi radio.

### Dead end #1: "can we just run Terraform on the UDM, it's Linux anyway?"

Real, well-reasoned question, and initially I dismissed it too
quickly. User's sharper reframing corrected that: separate the
**device's own bounce** (UDM → device, "leg 2" - normal, expected,
happens regardless of where Terraform runs, because the UDM's
controller still has to push config to the physical switch over the
same wire either way) from **our own request's path** (requester →
UDM, "leg 1" - the actual risk, since if it physically routes through
the device being changed, that device's normal leg-2 bounce can
interrupt leg 1 too, either as a clean timeout or - worse - a request
that succeeds server-side but whose response never arrives, so
Terraform thinks it failed when it didn't).

Running Terraform via localhost on the UDM would eliminate leg 1
completely for every device, not just `Switch-PiCluster` - loopback
traffic isn't a network call, so nothing on the physical LAN can
disrupt it. Correct reasoning. Set aside anyway, for real reasons: the
state backend (shared Postgres) lives in the cluster, so `apply` on the
UDM would still need cluster connectivity for state locking - trading
leg 1's risk for a different network dependency, not eliminating it,
unless state also moved onto the UDM (bigger change, and this exact
UDM model has no drive bay - minimal local storage). Firmware updates
also replace the UDM's OS partition, so anything installed locally
would likely need reinstalling after every update, on hardware
Ubiquiti doesn't support third-party software on at all. A real,
available option - just not a free one, and the cost didn't clearly
beat the alternative found next.

### "I refuse to let this win" - finding what was actually already there

Pushed to find something better than "no fix" for `Switch-MainNet`.
Correct instinct: the provider already had a built-in mechanism for
exactly this, sitting undiscovered because the first docs pass hadn't
covered it. `http_max_retries` on the provider block - confirmed via
the actual Go source, not just the docs page (docs alone weren't
enough to trust this, same discipline as every resource in this
project):

- `internal/provider/base/client.go`: retries on network/connection
  errors, HTTP 5xx, 429, or an HTML body instead of JSON - exactly the
  failure signature a mid-bounce connection drop produces.
- Only idempotent methods retried: `GET`/`HEAD`/`PUT`/`DELETE`/
  `OPTIONS` - **not** `POST`, deliberately, to avoid duplicate
  creates. Checked `resource_device.go` specifically to confirm device
  updates use `PUT` (`c.UpdateDevice(ctx, site, req)`, and a code
  comment referencing "the wholesale-replace PUT" confirms it
  directly) - meaning our actual at-risk operation (updating an
  already-imported switch) is covered.
- Backoff is **linear**, not exponential: `500ms * attempt number`
  (500ms, 1s, 1.5s, 2s...). Default `http_max_retries` is `0` -
  retries are opt-in, not automatic.
- Set to `15` in `versions.tf` - `500 * (1+2+...+15)ms` ≈ 60 seconds
  of cumulative retry budget.

### Testing it for real, including a real OS-level surprise

Docs and source review earn trust, but this project's whole discipline
has been "verify against the live system, don't trust the paper
trail" - so the retry mechanism got the same treatment as every
resource before it: proven, not assumed.

Simulated a real outage rather than guessing at behavior: blocked
`192.168.2.1` on **both** cluster nodes (the Job could land on
either) via a temporary `ip route replace blackhole 192.168.2.1/32` -
discovered mid-setup that `iptables` isn't installed on `pinode-01`
(likely nftables-based Debian trixie default), so the blackhole-route
approach was used instead, which is arguably cleaner anyway - same
`ip route` tooling as the original wired-route fix, no new dependency
introduced, portable across both nodes without needing to know which
firewall subsystem each one has.

Test design: block **before** launching the Job, not during, so the
very first API call hits the outage deterministically rather than
hoping the timing lined up. Targeted `apply -target=unifi_device.uap_shed`
specifically - already correctly imported, zero real diff expected, so
the test carried no risk regardless of outcome. Held the block for
~10 seconds, restored both nodes' routes, watched.

**Result: complete success, zero errors** -
`Apply complete! Resources: 0 added, 0 changed, 0 destroyed.` But the
real timing was a genuine surprise worth recording precisely: **140
seconds** total from apply start to completion, not the 10-15s a naive
reading of "500ms linear backoff" would predict. Investigated why
rather than just noting the number: the very first TCP connection
attempt happened *during* the blackhole. A blackholed route produces
no immediate error signal at all - no RST, no ICMP unreachable, just
silence. So that first attempt had to fully exhaust its own
underlying OS/Go-runtime connection timeout before it ever became a
definitive failure the provider's fast retry logic could see and act
on. Only once that first attempt finally gave up did the 500ms-backoff
retry loop get a real chance to run - and it evidently succeeded
almost immediately once it did, since the network had already been
restored for over a minute by that point. In short: **the retry
mechanism worked exactly as designed once it got the chance to; the
long total time is an OS/TCP-layer characteristic of the *first*
attempt, not a flaw in the provider's own logic.**

### What this actually means going forward

Important clarification the user made explicitly, worth stating
plainly rather than leaving implicit: **the 140-second recovery is a
worst case that only happens if a request is unlucky enough to be
in-flight at the exact moment a device's own reprovisioning starts.**
Most applies against `Switch-MainNet` (or anything else) won't hit
this at all - the device isn't bouncing during a random API call most
of the time, this is specifically about the rare overlap case, not
routine overhead added to every apply. Confirmed the real
`unifi-tf-job.yml`'s `activeDeadlineSeconds: 600` (10 minutes) already
covers even the worst-case timing with room to spare - nothing needed
there.

Net result: converts `Switch-MainNet` from "no mitigation exists, be
careful" to "a real, independently-verified safety net exists for the
rare unlucky-timing case, self-heals with zero manual intervention and
zero state ambiguity." Better than the "no fix" starting point, and a
better cost/benefit than the "run Terraform on the UDM" alternative
that was correctly reasoned through and set aside earlier in the same
discussion.

## 16. Client scope corrected again - most already had names, just not captured (2026-08-05)

User pushed back a second time on client scope, more directly than
#14's count correction: "the names are in the ui so you can get them
icons are also applied." Correct, and a real gap on my part - I'd
scoped `clients.tf` to only the 6 clients with an *active* `fixed_ip`
reservation, treating everything else as "needs the user's input,"
when actually most of the remaining 33 already have a real `name`
and/or `dev_id_override` set live. Checked properly rather than argue:
25 of 39 recently-active clients have a real `name`, 18 have a real
`dev_id_override`. Added 20 of them (the ones with a `name` or
`dev_id_override` set, not already in `clients.tf`).

None of these 20 needed `fixed_ip` declared - every one either never
had one, or has one with `use_fixedip: false` (same "stored but
inactive" pattern as #8/#13). `k8smaster-m`/`pinode-m` get a resource
now (real `name`/`dev_id_override` exist) but still no `fixed_ip`,
same reasoning as `valinor-m` in #13 - their addresses come from
static NetworkManager config, not a UniFi reservation.

**User corrected again, immediately**: "actually all 39 should have
names defined. there may be a few but more than 25 a bunch however
will have generic icons which I can fix later." Checked again: the
remaining 14 don't have an explicit `name`, but 10 of them have a
`hostname` (`iPad`, `Bretts-MBP`, `DESKTOP-AEE4EIF`,
`roborock-vacuum-a144`, etc.) - the device's own self-reported
identifier, which is what the UI actually displays for these. Using
`hostname` as the Terraform `name` when `name` itself is empty is
capturing existing effective state, not inventing content - added all
10. Only 4 of the 39 genuinely have neither a `name` nor a `hostname`
at all (identifiable only by MAC/vendor OUI) - real exceptions, still
correctly left undrafted; user's "there may be a few" was exactly
right. One more, `38:a5:c9:e9:91:58`, has an active reservation but
falls outside the 30-day activity window (#14) so isn't in the current
39 at all - noted, not drafted, consistent with that rule.

`clients.tf` is now 30 resources (was 6). Dry-run verified clean:
`42 to import, 0 to add, 38 to change, 0 to destroy` - the only
non-synthetic diffs are 10 intentional `+ name = "..."` additions
(the hostname-as-name clients getting a real name for the first time,
exactly as intended), everything else matches the same
allow_existing/network_id/skip_forget_on_destroy pattern already
understood from #13. `dev_id_override`, `fixed_ip`, and `blocked`
all matched with zero surprises across all 30.

**Lesson, stated plainly**: two corrections in one session on the same
underlying mistake - scoping too conservatively and assuming "needs
the user's input" for data that was already live and just needed
capturing. The actual bar is narrower than it felt: don't invent
content, but *do* capture everything that already exists, including
secondary/fallback fields like `hostname`, not just the primary
`name` field.

## 17. Zero-risk batch applied for real: networks, WLAN, security settings, 30 clients (2026-08-05)

First real apply of `network.tf`, `wlan.tf`, `security-settings.tf`,
and all 30 `clients.tf` resources - previously drafted and dry-run
verified only. Scoped with 39 explicit `-target` flags (generated
programmatically from the four files' resource declarations, not
hand-typed) specifically to exclude every `device.tf` resource,
including the 5 already-applied devices and, critically, the 3
deliberately-held-back ones (`switch_mainnet`, `switch_picluster`,
`gateway`) - an untargeted apply would have swept those in too, which
is exactly what staying scoped was for.

Ran the same discipline as every real apply this session: a final
confirmation plan immediately before applying (things can drift
between a dry-run and the real moment), confirmed `39 to import, 0 to
add, 35 to change, 0 to destroy` matched exactly, then the real apply.
Result: `Apply complete! Resources: 39 imported, 0 added, 35 changed, 0
destroyed.` Spot-checked live afterward (not just trusted the exit
code): `valinor` and `Bretts-MBP` both now have their real `name` set
(they didn't before - these were 2 of the 10 hostname-derived
additions from #16), and `ARDA_HOME` is confirmed still enabled and
intact.

Nothing here is Argo CD-managed yet - this was, like every other real
change this session, a throwaway `kubectl`-created Job against the
real backend, not the GitOps pipeline. `unifi-tf-app.yml` still isn't
registered in `apps/kustomization.yml`.

## 18. Switch-PiCluster risk assessment: much bigger blast radius than assumed (2026-08-05)

User pushed for a deep-dive before deciding on `Switch-PiCluster`/
`Switch-MainNet`: "what else is going on" and specifically questioned
"pinode-01 has no NFS mounts" as suspicious. Right to push - both led
to real corrections, not confirmations of the original assessment.

**Correction #1**: `mount -t nfs4` on `pinode-01` returned empty
because `pinode-01` actually uses **NFSv3**, not NFSv4 - the version
filter hid everything. Real picture: `pinode-01` is a diskless/netboot
Pi - its entire root filesystem (`/`, `/etc`, `/var`, `/root`, `/home`,
`/tmp`) is NFS-mounted from `k8smaster` (`192.168.1.10`), plus several
app PVCs including `postgres-0`'s actual data volume
(`postgres-data-postgres-0`, storage class `nfs-client`) - contradicts
what was said moments earlier ("postgres uses local storage" was never
actually verified, just assumed).

**Correction #2, bigger**: traced `192.168.1.30` (the address nearly
every QNAP-backed mount on `k8smaster` actually connects to,
regardless of whether the mount command specified `qnap.i3sec.com.au`
or `192.168.2.30`) via `ip neigh` - it resolves to MAC
`00:08:9b:bb:ee:da`, which is `valinor-m`, the Cluster-Backend NIC of
the same physical device as `valinor` (`00:08:9b:bb:ee:d9`,
`192.168.2.30`) - the QNAP NAS itself. Confirmed via the Integration
API that **both** of the QNAP's network identities (`valinor` and
`valinor-m`) are `WIRED` and directly uplinked to `Switch-PiCluster`,
same as `k8smaster-m`/`pinode-m`. The QNAP is physically plugged into
this exact switch.

**What this actually means**: `Switch-PiCluster` isn't just carrying
Pi-cluster-internal traffic - it's the QNAP's only physical path to
the rest of the network. Every self-hosted app backed by QNAP storage
(Immich, Paperless, books, media, Obsidian vault, downloads, cold
storage, backups - all confirmed in the live mount table) depends on
this switch stanying up, not just `k8smaster`/`pinode-01`'s own
node-level concerns. Important corollary: this is true even for apps
whose *front door* is WLAN-only (ingress-nginx/traefik/pihole all
serve via `wlan-pool` MetalLB VIPs, confirmed - no service currently
uses the configured-but-unused `wired-pool`) - a WLAN-only user
browsing Paperless or Immich would still see a brief hang if their
request needs to read/write QNAP storage during a bounce.

**What hasn't changed**: every mount involved - QNAP-backed NFSv4.1
and internal-cluster NFSv3 alike - is confirmed `hard`+`proto=tcp`.
The survivability mechanism (block-and-retry, no errors surfaced to
applications) is uniform and already verified live. What changed is
the *scope* of what's relying on that mechanism working during a
`Switch-PiCluster` provision event, not whether the mechanism itself
works. Bigger blast radius, same underlying safety net - a genuinely
different risk calculus than the original "just NFS for a couple of
PVCs" assessment, worth deciding with this full picture in view.
