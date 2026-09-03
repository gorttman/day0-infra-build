# Written to match live state exactly, pulled from the legacy REST API's
# networkconf endpoint during the inventory pass (README.md's "Inventory"
# section, HISTORY.md #6) - not guessed. DRAFT: not yet wired into
# kustomization.yml's configMapGenerator - a plan-only dry-run Job (never
# applied, see HISTORY.md) has confirmed a clean import with zero diff,
# but the real Job still needs to run this for real before it's live.
# "Internet 1" (purpose = wan) is intentionally NOT declared here - it's
# the system-managed WAN network, not a candidate for unifi_network.
#
# THE ONE DELIBERATE CODE-AHEAD-OF-LIVE DIVERGENCE (audit 2026-09-03):
# every other file in this directory is written to match the console
# exactly - the UDM is the authoritative source, and code is corrected to
# it, not the reverse. `dhcp_dns` is the single deliberate exception, on
# the user's explicit call: the three-entry list below is CORRECT and the
# console is what's wrong. Live is still handing out only 192.168.2.245 on
# all four DHCP networks, so commits 41cb0c7 ("hand out both Pi-holes") and
# f9b4f21 ("add 1.1.1.2 as the final fallback") are committed but never
# applied. A plan will therefore show 4 networks to change until someone
# runs the playbook with -e unifi_tf_do_apply=true. That is expected drift,
# not a mistake to be "fixed" by editing these values back down.
#
# METHODOLOGY NOTE (learned the hard way via the dry-run, see HISTORY.md):
# "no documented default -> safe to leave undeclared, Terraform adopts
# whatever's live" is WRONG for this provider. Undeclared optional
# fields fall back to the provider's schema default (or null), not the
# imported live value, regardless of what the docs claim about
# defaults - ipv6_ra_valid_lifetime's documented default (86400) doesn't
# even match this console's actual live value (0). The dry-run plan
# output is the only real ground truth; every field below was verified
# against it, not assumed from docs.
#
# Fields still deliberately NOT declared - now genuinely zero-diff,
# confirmed by the dry-run plan showing no change for them:
# - enabled, network_group, dhcp_lease, ipv6_interface_type,
#   network_isolation_enabled, vlan_id (Default only), site,
#   ipv6_ra_preferred_lifetime, ipv6_ra_priority, ipv6_pd_start/stop,
#   dhcp_v6_dns_auto, and all the wan_*/vpn_*/wireguard_* attributes
#   (not applicable to a LAN network).
#
# Fields with genuinely NO Terraform equivalent in this provider version
# - real live settings, dashboard-only: is_nat, nat_outbound_ip_addresses,
#   dhcpd_conflict_checking, dhcpd_wins_enabled, dhcpd_time_offset_enabled,
#   dhcpd_wpad_url, dhcpd_ntp_enabled, dhcpd_tftp_server,
#   dhcpd_unifi_controller, lte_lan_enabled, auto_scale_enabled,
#   gateway_type, setting_preference.

resource "unifi_network" "default" {
  name    = "Default"
  purpose = "corporate"
  subnet  = "192.168.2.1/24"
  # vlan_id intentionally omitted - live config has vlan_enabled: false,
  # this is the untagged/native network, not an explicitly tagged VLAN 1.

  domain_name              = "i3sec.com.au"
  internet_access_enabled  = true
  multicast_dns            = true # live: mdns_enabled

  dhcp_enabled = true
  dhcp_start   = "192.168.2.6"
  dhcp_stop    = "192.168.2.239"
  # live: dhcpd_dns_1 - Pi-hole's own service VIP. Deliberately the ONLY
  # entry, no fallback.
  #
  # 2026-08-23: was ["192.168.2.10", "192.168.2.1"] (k8smaster's node
  # IP) since the 2026-08-05 apply - nothing ever listened on port 53
  # there, so every DHCP-only WLAN client silently couldn't resolve
  # *.i3sec.com.au for ~3 weeks (confirmed via zero real-client hits in
  # Pi-hole's own query log).
  #
  # 2026-08-25: dropped the "192.168.2.1" (gateway) fallback added at
  # the same time. Confirmed live that 192.168.2.1 forwards straight to
  # public DNS with zero knowledge of *.i3sec.com.au - so any client
  # that silently fell back to it (a momentary Pi-hole timeout, a race
  # between the two servers, standard OS resolver retry behavior) got a
  # broken public answer instead of an error, with no visible sign why.
  # This is what was actually causing "works, then doesn't" on the
  # iPad/TV - not device state, not caching, a bad fallback resolver.
  # Single DNS server: if Pi-hole is ever actually down, resolution
  # should fail loudly, not silently return a wrong answer.
  # Two Pi-holes since 2026-09-03 (day2-services/apps/pihole), anchored to
  # different nodes with their VIPs so they cannot fail together, plus
  # 1.1.1.2 as a third and final entry.
  #
  # That third entry deliberately reverses the 2026-08-25 decision above, and
  # it is worth being honest that the reasoning there still holds: a public
  # resolver has no knowledge of *.i3sec.com.au, and a client that falls back
  # to it gets a working-looking public answer rather than an error. Resolvers
  # do not reliably try the list in order - several race or round-robin - so
  # this is not purely a last-resort path. What changed is the other side of
  # the trade: with one Pi-hole, the fallback fired on every routine restart,
  # which is exactly how the iPad/TV "works, then doesn't" symptom happened.
  # With two on separate nodes it should only fire if both are gone, and in
  # that case the choice is a wrong answer for internal names or no internet
  # at all. Accepted knowingly, not inherited.
  #
  # 1.1.1.2 (not 1.1.1.1) is Cloudflare's malware-blocking resolver, matching
  # what Pi-hole itself forwards to.
  dhcp_dns = ["192.168.2.245", "192.168.2.246", "1.1.1.2"]

  igmp_snooping         = false
  dhcp_guarding         = false # live: dhcpguard_enabled
  dhcpd_gateway_enabled = false # live: gateway auto-derived from subnet
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false

  # Both confirmed via dry-run plan diff, not docs - see methodology
  # note above. ipv6_ra_valid_lifetime is 0 live, NOT the documented 86400.
  ipv6_ra_enable          = true
  ipv6_ra_valid_lifetime  = 0
}

resource "unifi_network" "cluster_backend" {
  name    = "Cluster-Backend"
  purpose = "corporate"
  subnet  = "192.168.1.1/27"
  vlan_id = 10

  internet_access_enabled = false # live: internet_access_enabled false
  multicast_dns            = false # live: mdns_enabled false

  # DHCP is disabled on this network, but the start/stop range is still
  # stored live (not cleared) - confirmed via dry-run plan diff, which
  # showed these would be nulled out if left undeclared. "Disabled"
  # does not mean "unset" in UniFi's data model.
  dhcp_enabled = false
  dhcp_start   = "192.168.1.2"
  dhcp_stop    = "192.168.1.30"

  igmp_snooping         = false
  dhcp_guarding         = false
  dhcpd_gateway_enabled = false
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false

  ipv6_ra_enable         = true
  ipv6_ra_valid_lifetime = 0
}

# --- New networks, 2026-08-28 audit/redesign session ---
# Net-new VLANs, not yet bound to any SSID or populated with real
# client reservations - pure shell resources so the network/DHCP/
# firewall structure exists and can be verified via dry-run before any
# real device ever lands on them. VLAN IDs 20/30/40 chosen to avoid the
# existing 1 (Default, untagged) and 10 (Cluster-Backend).
#
# Trusted's own SSID + real device migration is deliberate follow-on
# work (real disruption: new SSID, every device needs the credentials
# re-entered once) - NOT part of this shell. IoT stays served by the
# existing ARDA_HOME SSID (still bound to Default) until Trusted is
# confirmed fully migrated off it - only then does ARDA_HOME get
# rebound to this network, with no rejoin required since its name/
# passphrase don't change.

resource "unifi_network" "trusted" {
  name    = "Trusted"
  purpose = "corporate"
  subnet  = "192.168.20.1/24"
  vlan_id = 20

  domain_name             = "i3sec.com.au"
  internet_access_enabled = true
  # multicast_dns = true was requested on both create AND a follow-up
  # update (2026-08-29) - both reported success with no error, but the
  # live API (rest/networkconf's mdns_enabled) came back false both
  # times, confirmed via direct GET, not just a stale terraform read.
  # Genuine provider/API quirk, not a timing fluke - capturing live
  # reality here so the plan stays honest rather than fighting a value
  # that won't stick. Revisit as a standalone follow-up (mDNS discovery
  # is a convenience setting, not safety-critical - not worth blocking
  # the network rollout over).
  multicast_dns = false

  dhcp_enabled = true
  dhcp_start   = "192.168.20.6"
  dhcp_stop    = "192.168.20.239"
  # Both Pi-holes plus the 1.1.1.2 final fallback - same list as Default,
  # see the full rationale in the Default resource above.
  dhcp_dns     = ["192.168.2.245", "192.168.2.246", "1.1.1.2"]

  igmp_snooping         = false
  dhcp_guarding         = false
  dhcpd_gateway_enabled = false
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false
}

resource "unifi_network" "guest" {
  name    = "Guest"
  purpose = "guest"
  subnet  = "192.168.30.1/24"
  vlan_id = 30

  domain_name             = "i3sec.com.au"
  internet_access_enabled = true
  multicast_dns           = false

  # network_isolation_enabled deliberately NOT set here - a real apply
  # 2026-08-29 failed with a live API error the provider docs never
  # mentioned: api.err.NetworkIsolationAppliedOnNonCorporateNetwork.
  # purpose = "guest" already carries its own native isolation from
  # every other local network - the explicit flag is only valid on
  # purpose = "corporate" networks (e.g. a locked-down internal VLAN
  # that still wants isolation without the guest-specific portal
  # behavior). Docs-vs-reality mismatch, same class of gotcha as every
  # other "verify via the live system" lesson in this project.

  dhcp_enabled = true
  dhcp_start   = "192.168.30.6"
  dhcp_stop    = "192.168.30.239"
  # Both Pi-holes plus the 1.1.1.2 final fallback - same list as Default,
  # see the full rationale in the Default resource above.
  dhcp_dns     = ["192.168.2.245", "192.168.2.246", "1.1.1.2"]

  igmp_snooping         = false
  dhcp_guarding         = false
  dhcpd_gateway_enabled = false
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false
}

resource "unifi_network" "iot" {
  name    = "IoT"
  purpose = "corporate"
  subnet  = "192.168.40.1/24"
  vlan_id = 40

  domain_name             = "i3sec.com.au"
  internet_access_enabled = true # per-device/per-band WAN egress is a firewall.tf concern, not a network-level toggle
  # multicast_dns = true was requested (most IoT integrations rely on
  # local mDNS/SSDP discovery) but hit the same live-API quirk as
  # Trusted below - both create and a follow-up update reported
  # success with no error, yet mdns_enabled read back false both
  # times, confirmed via direct GET. Genuine provider/API behavior,
  # not a fluke. Capturing live reality so the plan stays honest;
  # revisit as a standalone follow-up before any real IoT device
  # actually needs local discovery to work.
  multicast_dns = false

  dhcp_enabled = true
  dhcp_start   = "192.168.40.6"
  dhcp_stop    = "192.168.40.239"
  # Both Pi-holes plus the 1.1.1.2 final fallback - same list as Default,
  # see the full rationale in the Default resource above.
  dhcp_dns     = ["192.168.2.245", "192.168.2.246", "1.1.1.2"]

  igmp_snooping         = false
  dhcp_guarding         = false
  dhcpd_gateway_enabled = false
  dhcp_relay_enabled    = false
  upnp_lan_enabled      = false

  # NOT set here, deliberately: network_isolation_enabled. IoT needs
  # selective reachability (Trusted -> specific reserved IoT devices,
  # e.g. HA/spa-controller; IoT -> specific infra endpoints for HA/
  # Mosquitto) - a blanket isolation flag would block the exceptions
  # this design explicitly needs. Handled entirely in firewall.tf
  # instead - see the rules there for the absolute IoT<->Trusted
  # boundary, and their comments for what's still pending real device
  # data (the internet-egress address-banding, per-device allow-list).
}

# Declarative import - same pattern as cloudflare-tf/warp.tf's device
# default profile. Uses the provider's `name=` import ID format rather
# than a raw ID - a dry-run plan-only Job caught that the Integration
# API's `id` field (a UUID) fails with "Cannot import non-existent
# remote object": this provider is built on the legacy REST API
# underneath, whose network ID is a different, 24-char ObjectId (`_id`
# in the legacy API, not the Integration API's `id`/`external_id`).
# `name=` sidesteps needing either ID at all and is self-documenting.
import {
  to = unifi_network.default
  id = "name=Default"
}

import {
  to = unifi_network.cluster_backend
  id = "name=Cluster-Backend"
}
