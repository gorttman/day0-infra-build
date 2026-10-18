locals {
  # Ordered list matters: the catch-all (no hostname, service = http_status:404)
  # must be last, or it would swallow every request before the real rules run.
  tunnel_ingress_rules = concat(
    [for hostname, cfg in var.tunneled_hostnames : {
      hostname = hostname
      service  = cfg.origin
      origin_request = cfg.no_tls_verify ? {
        no_tls_verify = true
      } : null
    }],
    [{ service = "http_status:404" }]
  )
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "public_hostnames" {
  account_id = var.account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config = {
    ingress = local.tunnel_ingress_rules
  }
}

# DNS record for each tunneled hostname - the tunnel ingress config above
# only tells cloudflared where to route traffic; it doesn't create the
# public DNS entry that gets traffic to Cloudflare's edge in the first
# place. The dashboard's "Public Hostname" wizard does both atomically;
# managing the tunnel config via Terraform means this half has to be
# explicit too. Same map drives both - one hostname, one entry, both effects.
resource "cloudflare_dns_record" "tunnel_hostnames" {
  for_each = var.tunneled_hostnames

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # required "automatic" TTL for a proxied record
}
