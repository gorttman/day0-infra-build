terraform {
  required_version = ">= 1.7.0"

  required_providers {
    unifi = {
      source  = "filipowm/unifi"
      version = "~> 1.0"
    }
  }

  # State backend: shared Postgres instance (postgres.postgres.svc.cluster.local),
  # database "unifi_tf", owned by role "unifi_tf" - see README.md, same
  # pattern as apps/cloudflare-tf. conn_str is partial config, supplied at
  # `terraform init` via -backend-config from the TF_BACKEND_PG_CONN_STR
  # secret, never committed here.
  backend "pg" {}
}

provider "unifi" {
  api_url = var.unifi_api_url
  api_key = var.unifi_api_key

  # The Dream Machine's local controller API serves a self-signed cert -
  # same situation as qnap's origin override in cloudflare-tf/tunnel.tf.
  allow_insecure = true

  # Real resilience against a device's own reprovisioning bouncing OUR
  # request mid-flight (the leg-1/leg-2 distinction in HISTORY.md's
  # switch discussion) - not a default (provider defaults to 0, retries
  # disabled). Confirmed via the provider's actual source
  # (internal/provider/base/client.go): retries GET/HEAD/PUT/DELETE/
  # OPTIONS (device updates are PUT - confirmed in resource_device.go)
  # on network/connection errors, 5xx, 429, or HTML-instead-of-JSON.
  # Linear backoff: 500ms * attempt number. 15 retries = ~60s of
  # cumulative retry budget (500 * 15*16/2 ms) - sized against the
  # ~10-30s AP-radio-reprovision estimate with real headroom for a
  # switch, not just matched to it.
  http_max_retries = 15

  # Provisional: api_key is the preferred auth method (requires firmware
  # >= 9.0.108, see variables.tf). If the running firmware turns out to
  # be older, swap this block to `username = var.unifi_username` /
  # `password = var.unifi_password` instead - those variables already
  # exist for that fallback but aren't wired in here yet, since which
  # auth method actually applies isn't confirmed until the firmware
  # version is checked (see README.md).
}
