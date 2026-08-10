# Written to match live state exactly, pulled from the legacy REST API's
# get/setting endpoint (key=ips), during this stage's inventory
# (HISTORY.md #11) - not guessed. DRAFT: not yet wired into
# kustomization.yml, not imported for real yet - dry-run verified clean
# (0 diff) after fixing the import ID format, see below.
#
# This is a genuine exception to the "don't manage default-valued
# singletons" rule from README.md's Scope section - IPS here is NOT at
# UniFi's default. It's actively enabled in blocking mode with a real,
# curated threat-category list - exactly the kind of hand-tuned setting
# that rule always meant to include, not exclude.
#
# utm_token (a real secret-looking value in the live legacy JSON) has NO
# attribute anywhere in this provider's unifi_setting_ips schema -
# checked the complete attribute list, not just a curated summary.
# Almost certainly a Ubiquiti-cloud-issued credential for IPS signature
# updates, system-managed, not user-settable - nothing to declare, and
# nothing sensitive ends up in this file as a result.
#
# Legacy fields with no Terraform equivalent at all - dashboard-only:
# dns_filtering, content_filtering_blocking_page_enabled,
# endpoint_scanning, honeypot_enabled, last_alert_id, utm_token (above).
#
# Import ID: no "Import" section documented for this resource. First
# guess ("default" alone) failed with a genuinely helpful error - "ID
# does not contain site part. Format should be 'site:id'" - so it's the
# same site:id format network/wlan's docs mentioned for cross-site
# imports, just apparently required here even for the default site.
# id part is the "ips" setting's own legacy _id.

resource "unifi_setting_ips" "site" {
  ips_mode                     = "ips"
  advanced_filtering_preference = "manual"
  enabled_networks             = [unifi_network.default.id]

  enabled_categories = [
    "botcc",
    "dshield",
    "emerging-exploit",
    "emerging-malware",
    "emerging-mobile",
    "emerging-shellcode",
    "tor",
    "emerging-useragent",
    "emerging-worm",
    "dark-web-blocker-list",
    "malicious-hosts",
  ]

  # live true, documented default false - must be explicit.
  memory_optimized = true
}

import {
  to = unifi_setting_ips.site
  id = "default:607fc850afaf570510a1e6fd"
}
