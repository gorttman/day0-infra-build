# Import blocks removed (2026-08-10): unifi_user has no documented
# `terraform import` support at all (unlike network/wlan/setting_ips) -
# confirmed via dry-run, every import ID here failed with "cannot
# import non-existent remote object", initially misread as 35 stale
# client records. The real explanation: the provider's `allow_existing`
# attribute (default true) exists specifically so this resource can
# adopt an already-connected client by MAC match at apply time, without
# an import block at all. Dry-run with the import blocks removed shows
# a clean plan (35 to add, 0 to change, 0 to destroy) and no errors.
#
# Scope note (2026-08-04, HISTORY.md #11, corrected 2026-08-05 - see
# #14 and #16): recently-active clients (last_seen within 30 days) =
# 39, matches what the UniFi UI actually shows. Of those, 25 already
# have a real `name` set live and 18 already have a real
# `dev_id_override` (icon) set live - captured here as existing state,
# same as the original 6. This is NOT the "pick names/icons for every
# client" task - it's "stop leaving already-set real data undrafted."
# The remaining ~14 clients with genuinely nothing set (no name, no
# icon, no fixed_ip) still need the user's input before anything can
# be drafted for them - that part is unchanged.
#
# fixed_ip: NONE of the 20 clients added in #16 need it declared -
# every one either never had a fixed_ip at all, or has one with
# use_fixedip: false (stored but inactive, same "disabled ≠ unset"
# lesson as network.tf/#8). Only the original 6 (HISTORY.md #13) have
# a genuinely ACTIVE reservation.
#
# k8smaster-m/pinode-m - STALENESS FLAGGED, audit 2026-09-03, deliberately
# NOT changed: both still declare network_id = cluster_backend, which is
# exactly what the console stores, so this code is correct against live and
# the plan is clean. But both interfaces physically moved to Trusted
# (VLAN 20) in the 2026-08-30 backend migration - live
# last_connection_network_name reads "Trusted" for both. So it's the
# console's stored association that's stale against reality, not this file.
# Changing it here would be a live WRITE, not a capture, which is out of
# scope for an audit pass - raised for a decision instead.
#
# k8smaster-m/pinode-m: same reasoning as valinor-m in #13 for why
# fixed_ip stays undeclared (their addresses come from static
# NetworkManager config, not a UniFi reservation) - but unlike #13,
# these two DO have a real name + dev_id_override set live, so they
# get a resource now, just without fixed_ip. network_id is
# Cluster-Backend for these two specifically (last_connection_network_id
# confirms it), Default for everyone else.
#
# local_dns_record: none of the 20 new clients have one set live
# (local_dns_record_enabled: false, local_dns_record: "" where the
# field is present at all) - correctly omitted throughout, unlike 5 of
# the original 6.
#
# blocked = false declared explicitly on every new resource - no
# documented default for this attribute (same "don't assume, declare"
# lesson as network.tf/wlan.tf), live value confirmed false/absent for
# all of these.
#
# NOT drafted, no live name at all (name is REQUIRED, not inventing
# one): mac 00:08:9b:bb:ee:d9 (fixed_ip 192.168.2.30, from #13),
# mac 38:a5:c9:e9:91:58 (fixed_ip 192.168.2.29, from #13),
# mac a2:0a:48:a7:dc:3d (has dev_id_override 4511 but no name at all).
#
# user_group_id omitted for all - live usergroup_id is empty string
# (no override) throughout.
#
# Also found, not carried forward here: k8smaster has a "fixed AP" pin
# defined but disabled (fixed_ap_mac -> In-Wall-Office,
# fixed_ap_enabled: false) - not in the unifi_user schema fetched for
# this file, worth checking again if a "pin a client to its nearest AP"
# approach to the roaming problem is ever revisited.

resource "unifi_user" "googlehome_lounge" {
  mac              = "48:d6:d5:db:89:2e"
  name             = "googlehome lounge"
  fixed_ip         = "192.168.2.69"
  network_id       = unifi_network.default.id
  dev_id_override  = 2028
  local_dns_record = "googlehome-lounge.i3sec.com.au"
}

resource "unifi_user" "googlehome_shed" {
  mac              = "e4:f0:42:4e:f3:00"
  name             = "googlehome shed"
  fixed_ip         = "192.168.2.40"
  network_id       = unifi_network.default.id
  dev_id_override  = 2028
  local_dns_record = "googlehome-shed.i3sec.com.au"
}

resource "unifi_user" "googlehome_clock" {
  mac              = "08:38:e6:35:8e:aa"
  name             = "googlehome clock"
  fixed_ip         = "192.168.2.188"
  network_id       = unifi_network.default.id
  local_dns_record = "googlehome-clock.i3sec.com.au"
  # no dev_id_override live for this one specifically - not every
  # googlehome entry has one set, confirmed via the raw record.
}

resource "unifi_user" "googlehome_bar" {
  mac              = "00:f6:20:b3:7b:8a"
  name             = "googlehome bar"
  fixed_ip         = "192.168.2.197"
  network_id       = unifi_network.default.id
  dev_id_override  = 2028
  local_dns_record = "googlehome-bar.i3sec.com.au"
}

resource "unifi_user" "pinode_01" {
  mac              = "2c:cf:67:27:93:f2"
  name             = "pinode-01"
  fixed_ip         = "192.168.2.11"
  network_id       = unifi_network.default.id
  dev_id_override  = 4133
  local_dns_record = "pinode-01.i3sec.com.au"
}

resource "unifi_user" "k8smaster" {
  mac             = "88:a2:9e:2e:af:a1"
  name            = "k8smaster"
  fixed_ip        = "192.168.2.10"
  network_id      = unifi_network.default.id
  dev_id_override = 4133
  # local_dns_record live is "" (empty) with local_dns_record_enabled
  # false - genuinely not set, unlike the others. Omitted to match.
}

resource "unifi_user" "fetchbox_family_room" {
  mac             = "bc:14:ef:fd:1e:47"
  name            = "FetchBox Family Room"
  network_id      = unifi_network.default.id
  dev_id_override = 2494
  blocked         = false
}

resource "unifi_user" "printer_hp" {
  mac             = "e4:d5:3d:81:26:9e"
  name            = "Printer HP"
  network_id      = unifi_network.default.id
  dev_id_override = 2200
  blocked         = false
}

resource "unifi_user" "phone_base_station" {
  mac             = "7c:2f:80:99:9d:2c"
  name            = "Phone-Base-Station"
  network_id      = unifi_network.default.id
  dev_id_override = 4066
  blocked         = false
}

resource "unifi_user" "chromecast_pergola" {
  mac             = "88:3d:24:5b:0a:4e"
  name            = "Chromecast Pergola"
  network_id      = unifi_network.default.id
  dev_id_override = 39
  blocked         = false
}

resource "unifi_user" "fetchbox_pantry" {
  mac             = "e0:9f:2a:b3:95:22"
  name            = "FetchBox Pantry"
  network_id      = unifi_network.default.id
  dev_id_override = 2494
  blocked         = false
}

resource "unifi_user" "lg_tv_family_room" {
  mac             = "a8:a2:37:81:80:ea"
  name            = "LG-TV Family Room"
  network_id      = unifi_network.default.id
  dev_id_override = 38
  blocked         = false
}

resource "unifi_user" "marinas_ipad" {
  mac        = "ba:d6:43:c8:9a:a6"
  name       = "Marinas IPad"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "marinas_iphone" {
  mac        = "d2:9d:7f:58:0a:dd"
  name       = "Marinas IPhone"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "thermomix_2" {
  mac        = "58:16:d7:f3:27:9d"
  name       = "Thermomix 2"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "gpo_plug_base_pergola_2" {
  mac             = "40:f5:20:ee:71:74"
  name            = "GPO Plug-base pergola 2"
  network_id      = unifi_network.default.id
  dev_id_override = 4412
  blocked         = false
}

resource "unifi_user" "eufy_home_base" {
  mac        = "04:17:b6:7e:e8:37"
  name       = "Eufy Home Base"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "camera_garage" {
  mac        = "50:41:1c:88:23:56"
  name       = "Camera - Garage"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "bretts_iphone" {
  mac             = "26:cd:3e:0f:f4:18"
  name            = "Brett’s Iphone"
  network_id      = unifi_network.default.id
  dev_id_override = 5341
  blocked         = false
}

resource "unifi_user" "spa_controller_wifi" {
  mac        = "10:06:1c:4d:19:24"
  name       = "Spa Controller WiFi"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "spa_controller_fixed" {
  mac        = "10:06:1c:4d:19:27"
  name       = "Spa Controller Fixed"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "lg_tv_bedroom" {
  mac             = "40:2f:86:69:c6:50"
  name            = "LG-TV Bedroom"
  network_id      = unifi_network.default.id
  dev_id_override = 38
  blocked         = false
}

resource "unifi_user" "bretts_ipad" {
  mac             = "3a:97:ba:11:c4:e3"
  name            = "Bretts Ipad"
  network_id      = unifi_network.default.id
  dev_id_override = 4700
  blocked         = false
}

resource "unifi_user" "k8smaster_m" {
  mac             = "88:a2:9e:2e:af:a0"
  name            = "k8smaster-m"
  network_id      = unifi_network.cluster_backend.id
  dev_id_override = 4133
  blocked         = false
}

resource "unifi_user" "pinode_m" {
  mac             = "2c:cf:67:27:93:f1"
  name            = "pinode-m"
  network_id      = unifi_network.cluster_backend.id
  dev_id_override = 4133
  blocked         = false
}

# The remaining 10 don't have an explicit `name` set live, but DO have
# a `hostname` (the device's own self-reported name - "iPad",
# "Bretts-MBP", "DESKTOP-AEE4EIF", etc.) - that's what the UniFi UI
# actually displays for these, so using it as the Terraform `name` is
# capturing existing effective state, not inventing content. User's
# correction (2026-08-05): "all 39 should have names defined... a bunch
# will have generic icons which I can fix later" - confirmed: only 4 of
# the 39 genuinely have neither a name nor a hostname, see below.

resource "unifi_user" "valinor" {
  mac        = "00:08:9b:bb:ee:d9"
  name       = "valinor"
  fixed_ip   = "192.168.2.30" # live use_fixedip: true - genuinely active, unlike most of #16's batch
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "macbookair" {
  mac             = "a2:0a:48:a7:dc:3d"
  name            = "MacBookAir"
  network_id      = unifi_network.default.id
  dev_id_override = 4511
  blocked         = false
}

resource "unifi_user" "ipad_64f0" {
  mac        = "82:a3:27:87:64:f0"
  name       = "iPad"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "roborock_vacuum_a144" {
  mac        = "24:9e:7d:6e:a0:7b"
  name       = "roborock-vacuum-a144"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "ipad_67a6" {
  mac        = "d6:07:df:ce:67:a6"
  name       = "iPad"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "thermomix_90df0b" {
  mac        = "34:32:e6:90:df:0b"
  name       = "thermomix-90df0b"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "mnab53j7j34" {
  mac        = "8c:e9:ee:45:c6:df"
  name       = "MNAB53J7J34"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "bretts_mbp" {
  mac        = "fc:b2:14:af:61:5e"
  name       = "Bretts-MBP"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "lwip0" {
  mac        = "38:2c:e5:98:86:80"
  name       = "lwip0"
  network_id = unifi_network.default.id
  blocked    = false
}

resource "unifi_user" "desktop_aee4eif" {
  mac        = "dc:21:5c:97:2a:6b"
  name       = "DESKTOP-AEE4EIF"
  network_id = unifi_network.default.id
  blocked    = false
}

# The genuine "few" exceptions, confirmed by data, not assumption: no
# `name`, no `hostname` at all. `name` is required, not inventing one.
#   mac 00:00:01:08:82:84 (Xerox Corporation)
#   mac 7c:d5:66:a1:3f:41 (Amazon Technologies Inc.)
#   mac a8:1a:f1:49:1d:bb (Apple, Inc.)
#   mac 56:ad:52:8e:80:40 (no vendor OUI match either)
# Was also out of scope per the 30-day activity rule (HISTORY.md #14):
#   mac 38:a5:c9:e9:91:58, fixed_ip 192.168.2.29 (active reservation,
#   but last_seen outside the 30-day window - not in the current 39)
#
# UPDATE, audit 2026-09-03: that one is back IN scope - last_seen is now
# 2026-08-25, inside the window. It is the ONLY live-customised client
# still not represented in this file, and the only remaining gap between
# the console and this code for unifi_user.
#
# Still blocked on one thing, and only one: `name` is a REQUIRED argument
# on unifi_user (confirmed against the provider's own schema docs), and
# this record has no `name` set live. Its `hostname` is "wlan0", which is
# both useless as an identifier and shared with another device
# (c4:82:e1:1c:e3:9b), so the "hostname is effective state, not invented
# content" precedent used above does NOT hold here - writing "wlan0" would
# push a new, misleading name onto the console rather than capture one.
#
# What IS known about it, from the complete live record: 2.4GHz-only,
# associates via In-Wall-Office, on ARDA_HOME, active reservation
# 192.168.2.29, first seen 2025-09-28, no OUI/vendor fingerprint at all
# (so no automatic identification available either).
#
# Needs a real name from the user before it can be declared. Deliberately
# NOT left as a silent gap - see feedback_no_deferred_manual_steps.


################################################################################
# Audit pass 2026-09-03 - six clients that were live-customised but had no
# resource here. Found by diffing the complete live rest/user record set
# against this file; all six are within the 30-day activity rule.
#
# Captured EXACTLY as live, nothing invented - the UDM is the authoritative
# source for this pass, so every field below already has that value on the
# console and applying these should be a pure no-op adoption.
#
# network_id deliberately OMITTED on all six (unlike every resource above):
# live `network_id` is genuinely unset on each of these records - only the
# two -m interfaces have it set at all. Declaring `unifi_network.default.id`
# here would WRITE that association onto clients that don't currently have
# one, which is a change, not a capture. Verified per-record, not assumed.
#
# fixed_ip likewise omitted where live has `use_fixedip: false` - the
# address is stored but inactive, the same "disabled != unset" trap
# documented in network.tf and HISTORY.md #8. Applies to valinor-m
# (192.168.1.18) and GPO Pergola Double (192.168.2.15).

# Second interface on the QNAP. Distinct from `valinor` above
# (00:08:9b:bb:ee:d9) - different MAC, different record. Now connects on
# Trusted (VLAN 20) after the 2026-08-30 backend migration, but its stored
# network_id is unset, so nothing to declare for that here.
resource "unifi_user" "valinor_m" {
  mac             = "00:08:9b:bb:ee:da"
  name            = "valinor-m"
  dev_id_override = 4556
  blocked         = false
}

# Distinct from `bretts_mbp` above (fc:b2:14:af:61:5e) - a different
# physical machine, not a duplicate. This one has a real `name` set live;
# no dev_id_override on it.
resource "unifi_user" "bretts_macbook_pro" {
  mac      = "8c:85:90:49:86:ac"
  name     = "Brett's Macbook Pro"
  blocked  = false
}

# The four smart plugs. `gpo_plug_base_pergola_2` (40:f5:20:ee:71:74) was
# already captured further up - these are its four siblings, all carrying
# the same dev_id_override 4412 icon set by hand on the console.
resource "unifi_user" "gpo_outdoor_lighting_shed_2" {
  mac             = "84:cc:a8:8a:dd:45"
  name            = "GPO Outdoor-Lighting Shed-2"
  dev_id_override = 4412
  blocked         = false
}

resource "unifi_user" "gpo_shed_outdoor_lights" {
  mac             = "e0:98:06:16:a7:33"
  name            = "GPO shed outdoor lights"
  dev_id_override = 4412
  blocked         = false
}

resource "unifi_user" "gpo_plug_base_pergola_1" {
  mac             = "24:62:ab:3a:97:61"
  name            = "GPO Plug-base pergola 1"
  dev_id_override = 4412
  blocked         = false
}

resource "unifi_user" "gpo_pergola_double" {
  mac             = "c4:82:e1:1c:e3:9b"
  name            = "GPO Pergola Double"
  dev_id_override = 4412
  blocked         = false
}
