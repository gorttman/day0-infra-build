terraform {
  required_version = ">= 1.7.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # State backend: a local file, path supplied at init by the tf_run role
  # (-backend-config="path=..."). Lives at /var/lib/infra-tf/cloudflare/ on the
  # control host, with a vault-encrypted copy in day0-infra-build/state/.
  # Deliberately not in the cluster: this stack must work before k3s exists.
  backend "local" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
