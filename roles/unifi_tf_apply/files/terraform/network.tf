# Written to match live state exactly, pulled from the legacy REST API's
# networkconf endpoint during the inventory pass (README.md's "Inventory"
# section, HISTORY.md #6) - not guessed. DRAFT: not yet wired into
# kustomization.yml's configMapGenerator - a plan-only dry-run Job (never
# applied, see HISTORY.md) has confirmed a clean import with zero diff,
# but the real Job still needs to run this for real before it's live.
# "Internet 1" (purpose = wan) is intentionally NOT declared here - it's
# the system-managed WAN network, not a candidate for unifi_network.
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
  # live: dhcpd_dns_1/dhcpd_dns_2 - k8smaster first, then the gateway
  # itself as a fallback resolver.
  dhcp_dns = ["192.168.2.10", "192.168.2.1"]

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
