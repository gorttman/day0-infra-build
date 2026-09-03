# Confirmed empty via the original inventory pass (README.md's
# "Inventory" section, HISTORY.md #6/#11) - legacy firewallgroup/
# firewallrule were both genuinely 0 entries, "Zone Based Firewall is
# not configured" at that time (2026-08-04).
#
# IPS/threat-prevention config (which also lives under "security
# settings" conceptually) is NOT empty/default and is managed in
# security-settings.tf instead - see that file and HISTORY.md #11 for
# why it's a real exception to "don't manage default singletons".
#
# --- IoT<->Trusted isolation: BLOCKED on this provider, 2026-08-29 ---
#
# Real, live investigation, not a guess - full path documented here so
# nobody re-treads it blind:
#
# 1. Drafted the two rules below using unifi_firewall_rule (this
#    provider's only documented firewall-rule resource), schema
#    confirmed against the provider's own docs. Dry-run showed a clean
#    plan (2 to add), but the REAL apply failed both times with
#    api.err.FirewallRuleIndexOutOfRange, regardless of rule_index
#    value tried (2011/2012, then reasoned through to the 4000s LAN_IN
#    band - never got to test that, see #2).
# 2. Root cause, confirmed directly in the live UI: this console's
#    Network application now gates ALL new legacy-style "Firewall
#    Rules" behind a one-way "upgrade to Zone-Based Firewall" prompt -
#    explains the error completely, not a wrong index number. Verified
#    live: legacy rest/firewallrule and rest/firewallgroup are still
#    genuinely empty (0 entries) even now.
# 3. The provider DOES support zone-based firewall as first-class
#    resources (unifi_firewall_zone, unifi_firewall_zone_policy,
#    unifi_firewall_zone_policy_order - confirmed via the actual
#    GitHub docs directory listing, not inferred). Deliberately NOT
#    pursuing this path for now - migrating the whole console's
#    firewall model is a much bigger, likely one-way, completely
#    untested-by-us change, just to solve two rules on two currently-
#    empty networks. User's call, reasoned through explicitly.
# 4. Found a real, working, LOWER-risk mechanism instead: "ACL Rules",
#    a UI-creatable policy type that does NOT require the zone-based
#    migration (tested live - a real ACL rule was created successfully
#    via the UI while legacy Firewall Rules remained blocked). Schema
#    confirmed by creating a real test rule and reading it back via
#    GET on v2/api/site/default/acl-rules (NOT documented in the UI's
#    URL/menu naming - "ACL Rules" is a Policy Type inside "Traffic &
#    Firewall Rules", not its own top-level nav item):
#      {
#        "action": "BLOCK", "enabled": true, "type": "IPV4",
#        "ip_acl_protocol": "TCP_AND_UDP", "acl_index": 0,
#        "traffic_source":      {"type": "NETWORK", "network_ids": [<src network id>]},
#        "traffic_destination": {"type": "NETWORK", "network_ids": [<dst network id>]}
#      }
#    Known caveat (straight from the UI's own warning): ACL Rules do
#    NOT isolate traffic between two clients on the SAME AP. Reasoned
#    (not yet verified live) that this doesn't disqualify our use case
#    since IoT<->Trusted is cross-VLAN, and cross-VLAN traffic always
#    routes through the gateway regardless of shared AP - same-AP
#    hairpinning only applies within a single VLAN. MUST be verified
#    for real once actual devices exist on both networks (phase 2 SSID
#    rollout) - do not trust this reasoning as confirmed.
# 5. THE ACTUAL BLOCKER: this terraform provider (filipowm/unifi
#    v1.1.0) has NO resource for the v2 acl-rules endpoint at all -
#    confirmed against the complete current resource list (40 files,
#    github.com/filipowm/terraform-provider-unifi/tree/main/docs/resources,
#    fetched directly 2026-08-29, no acl_rule.md present). A newer
#    provider version might add it later - worth checking again before
#    building anything custom.
#
# DEFERRED 2026-08-29, then DROPPED 2026-09-03 on the user's explicit
# call ("acl we decided to drop for now so not needed"). The three
# options below are kept only as the record of what was investigated -
# none was chosen, and none is being pursued:
#   a) Manage the ACL rule manually via the UI, documented exception -
#      same pattern already used elsewhere in this project for genuine
#      dashboard-only settings.
#   b) Build a thin custom wrapper (e.g. the generic `http` provider,
#      or null_resource + direct API call) to bring it under code
#      anyway, matching this project's "everything as code" default.
#   c) Re-check provider support periodically, revisit once native.
#
# Provider support re-checked during the 2026-09-03 audit and still
# absent: the resource list is unchanged at 40 files, no acl_rule.md.
#
# The "test" ACL rule (IoT -> Trusted, BLOCK) created live during the
# 2026-08-29 investigation is GONE as of the 2026-09-03 audit -
# GET v2/api/site/default/acl-rules returns an empty array. Nobody
# recorded removing it; it may have gone with the firmware update. Its
# fate no longer needs deciding, but note the consequence: there is
# currently NO IoT<->Trusted isolation of any kind on this console.
# That is accepted for now precisely because both networks are still
# empty shells - it becomes a real exposure the moment phase 2 puts
# actual devices on them, so revisit BEFORE that rollout, not after.
#
# CONFIRMED STATE, audit 2026-09-03 - everything firewall-shaped on this
# console is genuinely empty, verified live by direct GET, not assumed:
#   rest/firewallrule            0
#   rest/firewallgroup           0
#   rest/portforward             0
#   rest/routing                 0
#   v2 firewall-policies         0
#   v2 firewall/zone             0
#   v2 trafficroutes             0
#   v2 qos-rules                 0
#   v2 acl-rules                 0
# So this file having no resources is correct against live, not a gap.
#
# unifi_firewall_rule resources intentionally NOT declared below -
# they cannot apply on this console as it stands (see #2 above). Kept
# here as commented reference for whichever option above gets chosen,
# not as live config:
#
# resource "unifi_firewall_rule" "iot_to_trusted_block" {
#   name       = "Block IoT to Trusted"
#   action     = "drop"
#   ruleset    = "LAN_IN"
#   rule_index = 2011
#   protocol   = "all"
#   src_network_id = unifi_network.iot.id
#   dst_network_id = unifi_network.trusted.id
# }
#
# resource "unifi_firewall_rule" "trusted_to_iot_default_block" {
#   name       = "Block Trusted to IoT (default-deny - add ACCEPT exceptions above this rule_index per device)"
#   action     = "drop"
#   ruleset    = "LAN_IN"
#   rule_index = 2012
#   protocol   = "all"
#   src_network_id = unifi_network.trusted.id
#   dst_network_id = unifi_network.iot.id
# }
#
# Also NOT written yet, deliberately: IoT -> WAN address-banding (some
# IoT devices allowed to route out, some not) and the specific
# per-device Trusted->IoT allow rules (HA, spa controller). Both need
# real reserved-IP data that doesn't exist until actual devices are
# onboarded, AND need the ACL-rule question above resolved first since
# they'd use the same mechanism.
