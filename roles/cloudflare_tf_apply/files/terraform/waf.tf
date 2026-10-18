locals {
  mtls_protected_hostnames = keys(var.tunneled_hostnames)

  fingerprint_clause = length(var.allowed_client_cert_fingerprints) > 0 ? (
    " or not (cf.tls_client_auth.cert_fingerprint_sha256 in {${join(" ", [for fp in var.allowed_client_cert_fingerprints : "\"${fp}\""])}})"
  ) : ""

  # Default-deny across the whole zone, not an allow-list of known
  # hostnames: a hostname published on the tunnel but never added here
  # used to be silently exposed with no client-cert check at all (this
  # already happened once with qnap). Now anything under i3sec.com.au
  # fails closed unless it presents a verified, non-revoked, and (if
  # fingerprint pinning is enabled) allow-listed cert.
  mtls_block_expression = "(http.host wildcard \"*.i3sec.com.au\" or http.host eq \"i3sec.com.au\") and (not cf.tls_client_auth.cert_verified or cf.tls_client_auth.cert_revoked${local.fingerprint_clause})"
}

resource "cloudflare_ruleset" "zone_mtls_enforcement" {
  zone_id     = var.zone_id
  name        = "Enforce mTLS on i3sec.com.au Services"
  description = "Blocks requests to protected self-hosted apps unless a valid, non-revoked client certificate is presented."
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [{
    ref         = "enforce_mtls_web_apps"
    description = "Default-deny: block any i3sec.com.au host unless client cert is verified, non-revoked, and (if fingerprint pinning is enabled) allow-listed"
    expression  = local.mtls_block_expression
    action      = "block"
    enabled     = true
  }]
}

# Separate from the WAF rule above - this is the TLS-layer setting that
# makes Cloudflare's edge actually *request* a client cert during the
# handshake for these hostnames in the first place. Without a hostname
# here, the WAF rule above still blocks it (no cert was ever presented),
# but the browser is never even prompted - looks identical to a broken
# WAF rule from the outside. No mtls_certificate_id set: hostnames
# associate to the active Cloudflare Managed CA (the same CA the 5
# registered device certs were issued under), matching existing behavior.
resource "cloudflare_certificate_authorities_hostname_associations" "mtls_hosts" {
  zone_id   = var.zone_id
  hostnames = local.mtls_protected_hostnames
}
