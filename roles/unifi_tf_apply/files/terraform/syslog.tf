# UDM remote syslog -> Alloy in the cluster (day2-services apps/alloy/udm-syslog),
# which forwards to Loki labelled app=udm, signal_type=network.
#
# Adopted from the live "rsyslogd" site setting (disabled, port 514,
# log_all_contents true at 2026-10-18) via the import block below, same
# site:id form as security-settings.tf. 192.168.20.231 is a MetalLB address
# on the Trusted VLAN that follows whichever Alloy pods are up.

resource "unifi_setting_rsyslogd" "site" {
  enabled          = true
  ip               = "192.168.20.231"
  port             = 514
  log_all_contents = true
  # The provider requires a contents list whenever enabled; with
  # log_all_contents true the UDM sends everything, so list every type.
  contents = [
    "device", "client", "firewall_default_policy", "triggers", "updates",
    "admin_activity", "critical", "security_detections", "vpn",
  ]
}

import {
  to = unifi_setting_rsyslogd.site
  id = "default:6229655c954f510366cce7a4"
}
