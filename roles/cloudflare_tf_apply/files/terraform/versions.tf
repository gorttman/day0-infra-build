terraform {
  required_version = ">= 1.7.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # State backend: shared Postgres instance (postgres.postgres.svc.cluster.local),
  # database "cloudflare_tf", owned by role "cloudflare_tf" — see README.md.
  # conn_str is partial config, supplied at `terraform init` via
  # -backend-config from the TF_BACKEND_PG_CONN_STR secret, never committed here.
  backend "pg" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
