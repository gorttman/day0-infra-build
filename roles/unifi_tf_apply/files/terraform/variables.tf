variable "unifi_api_url" {
  description = "Base URL of the Dream Machine's local controller API, injected as TF_VAR_unifi_api_url from the unifi-tf-secrets SealedSecret."
  type        = string
  default     = "https://192.168.2.1"
}

variable "unifi_api_key" {
  description = <<-EOT
    UniFi controller API key, injected as TF_VAR_unifi_api_key from the
    unifi-tf-secrets SealedSecret. Created via Control Plane > Admins &
    Users > (admin) > Create API Key - requires controller firmware
    >= 9.0.108. See README.md for the fallback (username/password) if
    the running firmware is older than that.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "unifi_username" {
  description = "Fallback auth if firmware is < 9.0.108 and API-key auth isn't available - a dedicated local admin account, not the console SSO login. Injected as TF_VAR_unifi_username. Leave empty when using unifi_api_key."
  type        = string
  default     = ""
}

variable "unifi_password" {
  description = "Password for unifi_username, injected as TF_VAR_unifi_password from the unifi-tf-secrets SealedSecret. Leave empty when using unifi_api_key."
  type        = string
  sensitive   = true
  default     = ""
}

variable "wlan_arda_home_passphrase" {
  description = "WPA pre-shared key for the ARDA_HOME WLAN (wlan.tf), injected as TF_VAR_wlan_arda_home_passphrase from the unifi-tf-secrets SealedSecret. Pulled live via the inventory pass - never written to a .tf file in plaintext."
  type        = string
  sensitive   = true
}
