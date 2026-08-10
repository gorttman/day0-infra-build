# No resources declared here on purpose - confirmed via the inventory
# pass (README.md's "Inventory" section, HISTORY.md #6) that both
# legacy firewallgroup and firewallrule are genuinely empty (0 entries
# each) on this console, and firewall/zones confirmed "Zone Based
# Firewall is not configured". Re-confirmed during this stage
# (HISTORY.md #11) - still empty. Nothing to import, nothing to write.
#
# IPS/threat-prevention config (which also lives under "security
# settings" conceptually) is NOT empty/default and is managed in
# security-settings.tf instead - see that file and HISTORY.md #11 for
# why it's a real exception to "don't manage default singletons".
#
# If firewall_group/firewall_rule are ever actually configured on this
# console, this file is where unifi_firewall_group/unifi_firewall_rule
# resources belong.
