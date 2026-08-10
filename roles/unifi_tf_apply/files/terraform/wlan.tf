# DRAFT - NOT committed to git, per explicit instruction. Validated via
# `terraform plan` only, run out-of-band against the same postgres
# backend/live credentials, entirely outside the git-tracked
# configMapGenerator so nothing here is picked up by the real
# unifi-tf-apply sync-hook Job unless and until it's deliberately
# committed later.
#
# Written to match live state exactly (pulled 2026-08-10 via the legacy
# REST API's wlanconf endpoint), except for two fields being restored
# to their pre-2026-08-05-incident values: fast_roaming_enabled and
# multicast_enhance. See homelab-book chapter 006 and
# unifi-tf/HISTORY.md #5 for the full incident this is fixing.
#
# network_id references unifi_network.default.id now that network.tf
# (pulled from the unifi-tf-inventory-findings branch) is included in
# this scratch test too - a real dependency, matching the original
# never-merged draft's intent, not a hardcoded magic string.

resource "unifi_wlan" "arda_home" {
  name          = "ARDA_HOME"
  security      = "wpapsk"
  passphrase    = var.wlan_arda_home_passphrase
  user_group_id = "5dcadb092d387c04fa8ff617" # built-in "Default" user group
  network_id    = unifi_network.default.id

  ap_group_ids = ["607fc0bdafaf570510a1e61a"] # live: the single "All APs" group

  wlan_bands = ["2g", "5g"] # live: wlan_band "both" / wlan_bands ["2g","5g"]

  hide_ssid          = false
  is_guest           = false
  mac_filter_enabled = false
  # Raw legacy JSON shows "allow", but the provider's own imported-state
  # read reports "deny" regardless while mac_filter is disabled - same
  # quirk the original draft documented, confirmed again via this
  # plan run. Functionally inert either way; matching the provider's
  # actual read to get a true zero-diff on this field.
  mac_filter_policy  = "deny"
  wpa3_support       = false
  wpa3_transition    = false

  # --- The two restorations ---
  # Both were lost when the SSID was rebuilt from UI defaults after the
  # 2026-08-05 accidental-destroy incident (confirmed via read-only
  # diff against the pre-incident live state). fast_roaming_enabled is
  # 802.11r fast BSS transition - the actual fix for the sticky-AP
  # roaming problem that motivated this whole project.
  fast_roaming_enabled = true
  multicast_enhance    = true

  # Live values differing from provider defaults - explicit to match
  # exactly, same discipline as network.tf's ipv6_ra_valid_lifetime
  # lesson noted in the original draft.
  minimum_data_rate_2g_kbps = 0
  minimum_data_rate_5g_kbps = 0
}

import {
  to = unifi_wlan.arda_home
  # Current live _id - this WLAN object was recreated after the
  # 2026-08-05 destroy, so this is NOT the same id the original
  # never-merged draft imported against (607fbf602d387c04fa8ff624).
  id = "6a73a3de7eae7c6ea8d8b462"
}
