# Fastmail migration (2026-08), MX-only setup - keeping Cloudflare as the
# authoritative DNS host, not delegating nameservers to Fastmail. Full NS
# delegation was Fastmail's default-offered path but would break every
# tunneled_hostnames entry in tunnel.tf - Cloudflare has to stay
# authoritative for the zone for the Tunnel to keep working at all.
#
# Deliberately NOT touching MX here. Current live MX (confirmed via public
# DNS, not guessed) is Google Workspace's aspmx.l.google.com (10) /
# alt1.aspmx.l.google.com (20) - switching to Fastmail's in1-smtp/in2-smtp
# is the actual point-of-no-return cutover step and goes in on its own,
# once mail import + parallel testing is done. The full cutover plan,
# current live records, and the unmanaged-MX trap are documented in
# ../FASTMAIL-CUTOVER.md - read that before touching MX.
# This file only adds records that are safe to have live before
# that: DKIM (unused until Fastmail is actually sending, harmless either
# way) and SPF/DMARC in monitor-safe form.

resource "cloudflare_dns_record" "fastmail_dkim" {
  for_each = toset(["fm1", "fm2", "fm3"])

  zone_id = var.zone_id
  name    = "${each.key}._domainkey.i3sec.com.au"
  type    = "CNAME"
  content = "${each.key}.i3sec.com.au.dkim.fmhosted.com"
  proxied = false # DKIM CNAMEs must resolve directly, not through Cloudflare's proxy
  ttl     = 3600
}

# SPF: no existing record today (confirmed via public DNS - only a
# google-site-verification TXT exists, no v=spf1 at all). Combining
# Google's and Fastmail's includes rather than just adding Fastmail's
# alone, because Google Workspace is still the live sender during the
# parallel-testing period - an SPF record that only authorizes Fastmail
# while Workspace keeps sending would make Workspace's own mail look
# worse than having no SPF record at all. Drop the google include once
# Workspace is actually cancelled.
resource "cloudflare_dns_record" "spf" {
  zone_id = var.zone_id
  name    = "i3sec.com.au"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.google.com include:spf.messagingengine.com ?all\""
  ttl     = 3600
}

# DMARC in monitor-only mode (p=none) - reports without rejecting or
# quarantining anything, deliberately the safest setting for a rollout.
# Tighten to p=quarantine or p=reject later, once the cutover has been
# stable for a while, not as part of this change.
resource "cloudflare_dns_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc.i3sec.com.au"
  type    = "TXT"
  content = "\"v=DMARC1; p=none;\""
  ttl     = 3600
}
