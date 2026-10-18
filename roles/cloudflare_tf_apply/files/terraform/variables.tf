variable "cloudflare_api_token" {
  description = "Cloudflare API token, injected as TF_VAR_cloudflare_api_token from the cloudflare-tf-secrets SealedSecret."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "Cloudflare account ID for Brett@i3sec.com.au's Account."
  type        = string
  default     = "c0ef76e1433049d74bcc9f96229eb866"
}

variable "zone_id" {
  description = "Zone ID for i3sec.com.au, injected as TF_VAR_zone_id from the cloudflare-tf-secrets SealedSecret."
  type        = string
}

variable "cloudflare_tunnel_id" {
  description = "UUID of the existing cloudflared Tunnel (token-based, created via the Zero Trust dashboard). Not a secret - an identifier, not a credential - visible in Zero Trust > Networks > Tunnels."
  type        = string
  default     = "e5de1f51-45bd-4357-83e8-9fb6574b8339"
}

variable "tunneled_hostnames" {
  description = <<-EOT
    Single source of truth for every hostname exposed via the Cloudflare
    Tunnel. Drives the tunnel's ingress config
    (cloudflare_zero_trust_tunnel_cloudflared_config, tunnel.tf), the
    public DNS record for each hostname (cloudflare_dns_record, tunnel.tf),
    the mTLS WAF rule's protected-hostname list (waf.tf, derived via
    keys()), and the mTLS Client Certificate hostname list
    (cloudflare_certificate_authorities_hostname_associations, waf.tf) -
    add a hostname here once and all four update. See README.md/HISTORY.md
    for why it took four separate resources to get here.

    `origin` defaults to the shared ingress-nginx-controller Service every
    k8s-hosted app in this cluster is fronted by (Cloudflare forwards by
    Host header; ingress-nginx does the final per-app routing via each
    app's own Ingress). Only override `origin` for things that aren't a
    k8s Service behind that controller - e.g. qnap, a physical NAS.
  EOT
  type = map(object({
    origin        = optional(string, "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local:80")
    no_tls_verify = optional(bool, false)
  }))
  default = {
    "argocd.i3sec.com.au"        = {}
    "paperless.i3sec.com.au"     = {}
    "books.i3sec.com.au"         = {}
    "vscode.i3sec.com.au"        = {}
    "homeassistant.i3sec.com.au" = {}
    # obsidian.i3sec.com.au removed 2026-07-19: obsidian was replaced with
    # the official headless Sync client (day2-services apps/obsidian),
    # which has no ingress/listening port at all, so there's nothing left
    # to publicly expose. novnc.i3sec.com.au stays - still tunneled for
    # the unrelated `mac` target.
    "novnc.i3sec.com.au"         = {}
    # arr-stack (2026-07-21) - all seven public by explicit choice, not
    # the default for this class of app (config-once/runs-in-background
    # apps like these don't usually need it - see day2-services'
    # arr-stack/README.md). Origins are all the shared ingress-nginx-
    # controller default like everything else here; arr-stack itself is
    # a k8s Deployment, same as any other app on this cluster - nothing
    # special about it needing an origin override the way qnap
    # (a physical NAS) does below. Still gated by the same zone-wide
    # mTLS WAF rule as everything else - no separate app-level auth
    # layered on for any of them, matching this cluster's norm.
    "sonarr.i3sec.com.au"        = {}
    "radarr.i3sec.com.au"        = {}
    "prowlarr.i3sec.com.au"      = {}
    "sabnzbd.i3sec.com.au"       = {}
    "lazylibrarian.i3sec.com.au" = {}
    # whisparr added 2026-09-03. It joined arr-stack on 2026-08-27, after
    # the 2026-07-21 pass above, and was missed by both halves of the
    # treatment - no entry here and no nginx "-public" ingress. The effect
    # was that whisparr.i3sec.com.au resolved only via Pi-hole to the LAN
    # Traefik VIP, with no public A record at all, so any device not
    # actually using Pi-hole for DNS (an iPad on iCloud Private Relay,
    # cellular, a VPN) could not reach it while every sibling app worked.
    "whisparr.i3sec.com.au"      = {}
    "qnap.i3sec.com.au" = {
      origin        = "https://192.168.2.30:443"
      no_tls_verify = true # confirmed 2026-07-15: QNAP (QTS) serves a self-signed cert even after regenerating it with a correct CN/SAN for qnap.i3sec.com.au - cloudflared has no way to verify it against a public CA, so this stays true. Unrelated to the iPad LAN-side cert trust fix from the same date (see dns-conf/pihole/README.md) - that only covers direct browser access, not cloudflared's origin connection.
    }
    # Added 2026-08-21 for off-LAN phone access to the photo library.
    # Immich's own ingress uses Traefik, not the shared ingress-nginx-
    # controller every other app here goes through (confirmed via
    # `kubectl get ingress -n immich` showing IngressClass "traefik") -
    # rather than route through a second ingress controller, this points
    # straight at the immich-server ClusterIP Service, same plain-HTTP
    # cluster-internal pattern as the default origin, just a different
    # Service. Gated by the same zone-wide mTLS WAF rule as everything
    # else - no separate app-level auth layered on.
    "immich.i3sec.com.au" = {
      origin = "http://immich-server.immich.svc.cluster.local:2283"
    }
    # Added 2026-09-08 for off-LAN Jellyfin access. Like immich, jellyfin's
    # ingress is Traefik-class (jellyfin-ingress.yml, ingressClassName:
    # traefik), not the shared ingress-nginx-controller - so this points
    # straight at the jellyfin ClusterIP Service (plain HTTP on 8096),
    # bypassing the Ingress the same way the immich entry does.
    #
    # Off-LAN this sits behind the same zone-wide mTLS WAF rule as every
    # other host here, which the Jellyfin native apps (Swiftfin, the
    # Android/TV clients) can't satisfy - they don't do client-cert auth.
    # That's by design, not a gap: split-horizon DNS already publishes
    # jellyfin.i3sec.com.au -> 192.168.20.239 (the LAN Traefik VIP) via
    # Pi-hole and CoreDNS, so on-LAN the native apps hit Traefik directly
    # and never see Cloudflare or the mTLS gate. Off-LAN is browser-only
    # on a cert-carrying device, same as everything else.
    "jellyfin.i3sec.com.au" = {
      origin = "http://jellyfin.jellyfin.svc.cluster.local:8096"
    }
    # Added 2026-09-26: the homelab reports and the Grafana dashboards
    # behind them, for off-LAN access. All three use Traefik-class ingresses
    # (not ingress-nginx), so like immich/jellyfin above each points straight
    # at its ClusterIP Service. Same zone-wide mTLS WAF gate as everything
    # else; Grafana keeps its own login on top. On-LAN, Pi-hole/CoreDNS
    # still resolve all three to the Traefik VIP (split-horizon).
    "reports.i3sec.com.au" = {
      origin = "http://reports.reports.svc.cluster.local:80"
    }
    "grafana.i3sec.com.au" = {
      origin = "http://grafana.monitoring.svc.cluster.local:3000"
    }
    "movie-status.i3sec.com.au" = {
      origin = "http://movie-status.arr-stack.svc.cluster.local:80"
    }
    # Added 2026-09-27 for the AI platform build (build plan Stage 0 spike, Stage 4
    # daily-driver): Open WebUI, off-LAN, behind the same zone-wide mTLS gate.
    # Traefik-class app like grafana/immich, so the origin is its ClusterIP Service.
    "open-webui.i3sec.com.au" = {
      origin = "http://open-webui.open-webui.svc.cluster.local:80"
    }
    # Added 2026-10-13 for off-LAN Music Assistant (web UI only; the Cast/AirPlay
    # speakers stay LAN-side and pull audio straight from the node on :8097).
    # Traefik-class ingress like grafana/immich, so the origin is the ClusterIP
    # Service. Same zone-wide mTLS WAF gate as everything else; MA keeps its own
    # login on top. On-LAN, Pi-hole/CoreDNS still resolve it to the Traefik VIP.
    "music.i3sec.com.au" = {
      origin = "http://music-assistant.music-assistant.svc.cluster.local:8095"
    }
  }
}

variable "allowed_client_cert_fingerprints" {
  description = "SHA-256 fingerprints of specific client certs permitted to pass the mTLS WAF rule. Empty = accept any cert issued under this account's CA. This deployment always seals a real, non-empty list here (see cloudflare-tf-secrets / README.md's device table) - empty is only ever the default for a from-scratch bootstrap, not this cluster's live behavior."
  type    = list(string)
  default = []
}

variable "k8smaster_lan_ip" {
  description = "IP of the k3s control-plane node, reachable over the tunnel's private network route once WARP is enrolled. 192.168.20.10 (Trusted/VLAN20) since the 2026-08-30 backend migration - the old main-LAN 192.168.2.10 no longer answers, so the WARP SSH route silently pointed at nothing until corrected 2026-10-03."
  type        = string
  default     = "192.168.20.10"
}

variable "unifi_udm_lan_ip" {
  description = "LAN IP of the UniFi Dream Machine's admin console, reachable over the tunnel's private network route once WARP is enrolled - added 2026-08-16 after finding there was no off-LAN path to it at all (not on the public tunnel, not on the existing WARP route, which only covered k8smaster)."
  type        = string
  default     = "192.168.2.1"
}

variable "qnap_lan_ip" {
  description = "LAN IP of the QNAP (valinor) on eth0, reachable over the tunnel's private network route once WARP is enrolled - added 2026-08-16 for off-LAN SMB access (iPad/Mac photo editing workflow). Matches the k8smaster/UDM routes' 192.168.2.0/24 subnet - see qnap_wired_lan_ip for the other homed address."
  type        = string
  default     = "192.168.2.30"
}

variable "qnap_wired_lan_ip" {
  description = "LAN IP of the QNAP (valinor) on eth1 - the other half of its dual-homing (192.168.1.30, same subnet as k8smaster's wired end0). Added 2026-08-16 alongside qnap_lan_ip: SMB worked over this address from the iPad but not yet over 192.168.2.30, so both are routed simultaneously for live A/B testing rather than guessing which one to commit to. Collapse back to one once the working address is confirmed - see warp.tf's header comment."
  type        = string
  default     = "192.168.1.30"
}

variable "warp_authorized_emails" {
  description = "Only these emails may enroll a device in Cloudflare WARP for this account. Auth still goes through the onetimepin IdP - this just gates who's allowed to complete enrollment."
  type        = list(string)
  default     = ["gorttman@i3sec.com.au", "brett@i3sec.com.au"]
}
