# WARP client access to k8smaster (192.168.20.10) for off-LAN SSH, e.g. while
# travelling. Three pieces, all required together:
#
#   1. A private network route on the existing tunnel, so 192.168.20.10 is
#      reachable through it at all.
#   2. The account's default WARP device profile, switched from its stock
#      "exclude everything private" split-tunnel mode to "include only
#      k8smaster" mode. This account has no other Zero Trust use case (no
#      other Access apps, no Gateway filtering depended on today), so
#      routing *only* k8smaster through WARP - and letting all other device
#      traffic bypass WARP entirely - is simpler and lower-impact than
#      carving a single /32 hole out of the existing 192.168.0.0/16 exclude
#      (which would need ~16 explicit complement CIDRs to express and would
#      pull all other traffic through Cloudflare for every enrolled device).
#   3. A `warp`-type Access Application gating device enrollment to just the
#      two people who'll ever use this - everyone else's OTP still gets
#      accepted by the identity provider, but only these emails are allowed
#      to finish enrolling a device.
#
# Once enrolled, SSH itself is unchanged: same key, same `ssh 192.168.20.10`,
# WARP only provides the network path when off the home LAN.
#
# Extended 2026-08-16 to also cover the UniFi Dream Machine's admin console
# (192.168.2.1) - same off-LAN access gap, same fix, one more /32. Chose
# extending this existing route over either alternative: a public tunneled
# hostname would put router admin on the open internet (a meaningfully
# bigger attack surface than a WARP-only route, even mTLS-gated); a
# separate second WARP route would work but there's no reason to duplicate
# the device-profile/enrollment plumbing for what's still just "a couple
# of trusted LAN IPs reachable off-network."

resource "cloudflare_zero_trust_tunnel_cloudflared_route" "k8smaster" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "${var.k8smaster_lan_ip}/32"
  comment    = "k8smaster - private SSH access via WARP"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_route" "unifi_udm" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "${var.unifi_udm_lan_ip}/32"
  comment    = "UniFi Dream Machine - private admin console access via WARP"
}

# Added 2026-08-16: off-LAN SMB access to the QNAP for the iPad/Mac photo
# editing workflow (Affinity Photo editing files directly on the QNAP
# share, rather than round-tripping through a separate cloud library).
# SMB itself was also disabled at the OS level until this same session
# (see /etc/config/uLinux.conf [Samba] Enable) - this route alone doesn't
# get you SMB access without that also being on.
#
# Originally routed only 192.168.2.30 (eth0), to match the subnet this
# file's other two routes use. That address wouldn't connect from the
# iPad while 192.168.1.30 (eth1) did, so both are routed simultaneously
# for now - live A/B testing beats guessing which one is actually the
# problem. Collapse back to a single qnap route (matching k8smaster/
# unifi_udm's pattern above) once one address is confirmed working -
# this dual-route state is deliberately temporary, not the new norm.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "qnap" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "${var.qnap_lan_ip}/32"
  comment    = "QNAP (valinor) - private SMB access via WARP (eth0)"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_route" "qnap_wired" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "${var.qnap_wired_lan_ip}/32"
  comment    = "QNAP (valinor) - private SMB access via WARP (eth1, A/B test)"
}

# Pre-existing singleton (one per account, created outside Terraform).
# The import block below adopts it declaratively: a no-op if it's already
# in state (the normal case), an automatic adopt-instead-of-create if
# state is ever empty (a from-scratch rebuild of the Postgres backend) -
# no separate manual `terraform import` command to remember or re-run.
resource "cloudflare_zero_trust_device_default_profile" "this" {
  account_id = var.account_id

  include = [
    {
      address     = "${var.k8smaster_lan_ip}/32"
      description = "k8smaster - private SSH access"
    },
    {
      address     = "${var.unifi_udm_lan_ip}/32"
      description = "UniFi Dream Machine - private admin console access"
    },
    {
      address     = "${var.qnap_lan_ip}/32"
      description = "QNAP (valinor) - private SMB access (eth0)"
    },
    {
      address     = "${var.qnap_wired_lan_ip}/32"
      description = "QNAP (valinor) - private SMB access (eth1, A/B test)"
    },
  ]
}

import {
  to = cloudflare_zero_trust_device_default_profile.this
  id = var.account_id
}

resource "cloudflare_zero_trust_access_application" "warp_enrollment" {
  account_id = var.account_id
  type       = "warp"
  name       = "Warp Login App" # matches the live dashboard name (renamed there by hand); kept as-is 2026-10-03

  policies = [{
    name       = "Authorized WARP users"
    decision   = "allow"
    precedence = 1
    include    = [for email in var.warp_authorized_emails : { email = { email = email } }]
  }]
}
