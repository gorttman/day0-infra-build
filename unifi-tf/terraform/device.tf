# Written to match live state exactly, pulled from the legacy REST API's
# stat/device endpoint (HISTORY.md #10) - not guessed. DRAFT: not yet
# wired into kustomization.yml, not imported for real yet.
#
# forget_on_destroy = false is set on EVERY device below, deliberately,
# non-negotiably - the provider's documented default is true, which
# means Terraform un-adopting real physical hardware is one bad
# `terraform destroy` or forced-replacement away. This is real
# infrastructure, not throwaway cloud resources; nothing here should
# ever be able to un-adopt a device as a side effect.
#
# allow_adoption is left undeclared - it only matters at create time
# (attempting to adopt a not-yet-adopted device), and every device here
# is being imported (already adopted), not created.
#
# tx_power is omitted everywhere - only relevant when
# tx_power_mode = "custom", which no radio on this console uses.
#
# FINDING WORTH FLAGGING SEPARATELY (not acted on here - this stage is
# capture-current-state only, see README.md's "no batching a change
# into an import" discipline): In-Wall-Office has min_rssi_enabled=true
# (kicks clients below -76dBm) on both radios; In-Wall-Bar has NO
# min-RSSI setting at all (min_rssi_enabled/min_rssi both entirely
# absent from the live API response, not just false). That asymmetry is
# a real, concrete candidate for the sticky-AP roaming fix - a weak
# client on Bar is never forced to roam back toward Office. Deliberately
# NOT changed here; this file only captures what's live today.

resource "unifi_device" "switch_mainnet" {
  mac                = "74:ac:b9:e0:16:f3"
  name               = "Switch-MainNet"
  forget_on_destroy  = false
}

resource "unifi_device" "switch_picluster" {
  mac                = "78:8a:20:7f:70:93"
  name               = "Switch-PiCluster"
  forget_on_destroy  = false

  # Four real live port overrides, pulled from stat/device's
  # port_overrides - same finding as gateway above, but higher stakes:
  # ports 3/7/8 carry Cluster-Backend (native VLAN 10) to specific
  # physical ports, almost certainly the actual Pi cluster wiring (see
  # HISTORY.md #10 - matches the fixed-IP static clients on
  # 192.168.1.x: pinode-m, k8smaster-m, valinor-m). Getting this wrong
  # risks real cluster connectivity, not just Wi-Fi convenience -
  # verified via dry-run before this is trusted at all.
  #
  # Legacy fields with no Terraform equivalent on any of these four
  # ports, dashboard-only: speed, full_duplex, autoneg, all stormctrl_*,
  # port_security_*, isolation, lldpmed_enabled, port_keepalive_enabled,
  # multicast_router_networkconf_ids, stp_port_mode,
  # egress_rate_limit_kbps_enabled.

  port_override {
    number                = 2
    name                  = "Port 2"
    forward                = "all"
    native_networkconf_id = unifi_network.default.id
    tagged_vlan_mgmt      = "auto"
    poe_mode               = "off"
    setting_preference     = "manual"
  }

  port_override {
    number                = 3
    name                  = "Port 3"
    forward                = "customize"
    native_networkconf_id = unifi_network.cluster_backend.id
    tagged_vlan_mgmt      = "auto"
    poe_mode               = "off"
    setting_preference     = "manual"
  }

  port_override {
    number                = 7
    name                  = "Port 7"
    forward                = "customize"
    native_networkconf_id = unifi_network.cluster_backend.id
    tagged_vlan_mgmt      = "auto"
    poe_mode               = "auto"
    setting_preference     = "manual"
  }

  port_override {
    number                = 8
    name                  = "Port 8"
    forward                = "customize"
    native_networkconf_id = unifi_network.cluster_backend.id
    tagged_vlan_mgmt      = "auto"
    poe_mode               = "auto"
    setting_preference     = "manual"
  }
}

resource "unifi_device" "gateway" {
  mac               = "f4:92:bf:95:c6:d5"
  name              = "Gateway"
  forget_on_destroy = false

  # Real live port override, pulled from stat/device's port_overrides -
  # caught by the dry-run wanting to null it out, since it wasn't
  # captured when this file only looked at radio_table (HISTORY.md #10).
  port_override {
    number                = 4
    name                  = "Switch"
    forward                = "all"
    native_networkconf_id = unifi_network.default.id
    tagged_vlan_mgmt      = "auto"
  }

  radio {
    name             = "ng"
    channel          = "1"
    ht               = 20
    tx_power_mode    = "medium"
    min_rssi_enabled = true
    min_rssi         = -86
  }
  radio {
    name             = "na"
    channel          = "48"
    ht               = 80
    tx_power_mode    = "medium"
    min_rssi_enabled = true
    min_rssi         = -86
  }
}

resource "unifi_device" "in_wall_bedroom" {
  mac               = "70:a7:41:e5:a7:a3"
  name              = "In-Wall-Bedroom"
  forget_on_destroy = false

  radio {
    name             = "ng"
    channel          = "11"
    ht               = 40
    tx_power_mode    = "high"
    min_rssi_enabled = false
    min_rssi         = -90
  }
  radio {
    name             = "na"
    channel          = "157"
    ht               = 40
    tx_power_mode    = "high"
    min_rssi_enabled = false
    min_rssi         = -90
  }
}

resource "unifi_device" "uap_shed" {
  mac               = "80:2a:a8:56:a6:49"
  name              = "UAP - Shed"
  forget_on_destroy = false

  radio {
    name             = "ng"
    channel          = "11"
    ht               = 20
    tx_power_mode    = "medium"
    min_rssi_enabled = false
    min_rssi         = -90
  }
  radio {
    name             = "na"
    channel          = "48"
    ht               = 40
    tx_power_mode    = "medium"
    min_rssi_enabled = false
    min_rssi         = -90
  }
}

resource "unifi_device" "in_wall_office" {
  mac               = "78:8a:20:d6:93:8b"
  name              = "In-Wall-Office"
  forget_on_destroy = false

  radio {
    name             = "ng"
    channel          = "auto"
    ht               = 20
    tx_power_mode    = "high"
    min_rssi_enabled = true
    min_rssi         = -76
  }
  radio {
    name             = "na"
    channel          = "165"
    ht               = 20
    tx_power_mode    = "high"
    min_rssi_enabled = true
    min_rssi         = -76
  }
}

resource "unifi_device" "in_wall_bar" {
  mac               = "28:70:4e:86:db:fd"
  name              = "In-Wall-Bar"
  forget_on_destroy = false

  # tx_power_mode/min_rssi_enabled/min_rssi deliberately NOT declared -
  # live API returns them as entirely absent (not false/null-as-a-value)
  # for this device, unlike every other AP here. Left undeclared per the
  # "don't guess, let the dry-run tell you" methodology (HISTORY.md
  # #8/#9) rather than assuming a value with no live signal to match.
  radio {
    name    = "ng"
    channel = "1"
    ht      = 20
  }
  radio {
    name    = "na"
    channel = "153"
    ht      = 40
  }
}

resource "unifi_device" "in_wall_lounge" {
  mac               = "28:70:4e:86:ca:19"
  name              = "In-Wall Lounge"
  forget_on_destroy = false

  radio {
    name             = "ng"
    channel          = "1"
    ht               = 20
    tx_power_mode    = "auto"
    min_rssi_enabled = false
  }
  radio {
    name             = "na"
    channel          = "149"
    ht               = 40
    tx_power_mode    = "auto"
    min_rssi_enabled = false
  }
}

# Import IDs: no "Import" section in the provider's device.md docs at
# all (unlike network/wlan) - trying the legacy _id format first, same
# as unifi_wlan, confirming via dry-run rather than guessing blind.
import {
  to = unifi_device.switch_mainnet
  id = "607fc748afaf570510a1e6ea"
}
import {
  to = unifi_device.switch_picluster
  id = "68d6409f1da50b72d529c7c5"
}
import {
  to = unifi_device.gateway
  id = "656449dab2408d297eb8d659"
}
import {
  to = unifi_device.in_wall_bedroom
  id = "641e7e7577ae6e03709da1e4"
}
import {
  to = unifi_device.uap_shed
  id = "6082121eafaf570510a22155"
}
import {
  to = unifi_device.in_wall_office
  id = "622958e5954f510366cce425"
}
import {
  to = unifi_device.in_wall_bar
  id = "673fcd35c782ac7bda23deac"
}
import {
  to = unifi_device.in_wall_lounge
  id = "673c3889c782ac7bda232bf4"
}
