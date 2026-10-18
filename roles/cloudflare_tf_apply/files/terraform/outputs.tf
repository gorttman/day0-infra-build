output "mtls_rule_expression" {
  description = "The actual WAF rule expression applied — check this in plan output before it's ever allowed to run against a real token."
  value       = local.mtls_block_expression
}

output "mtls_ruleset_id" {
  value = cloudflare_ruleset.zone_mtls_enforcement.id
}

output "tunnel_ingress_rules" {
  description = "The actual tunnel ingress rules applied — check this in plan output before it's ever allowed to run against the real tunnel."
  value       = local.tunnel_ingress_rules
}

output "warp_authorized_emails" {
  description = "Emails allowed to enroll a device in WARP — check this in plan output before it's ever allowed to run for real."
  value       = var.warp_authorized_emails
}
