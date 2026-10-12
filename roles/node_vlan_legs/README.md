# node_vlan_legs

Per-node network pieces for the Bose / IoT VLAN work (2026-10-12):

- A **tagged IoT VLAN (40) sub-interface** (`iot40`, e.g. `eth0.40`) so Music
  Assistant (hostNetwork) shares a subnet with the Bose and Sendspin nodes
  wherever the pod lands. No gateway, no default route; the node's own address
  and routes are untouched. Address block: `.10-.19` for nodes
  (`192.168.40.0/24`; `.21-.50` is reserved for sound/HID devices, DHCP is `.51+`).
- The node's **own resolver list** reconciled to `wifi_mgmt_dns` (Pi-hole A,
  Pi-hole B, then 1.1.1.2). The fallback is deliberate: a node whose only DNS is
  the Pi-hole VIP cannot pull the Pi-hole image, so it cannot start Pi-hole
  (2026-09-03). pinode-01 had drifted to the old `192.168.2.x` VIPs.

Opt in per host in `variables/cli/host_vars/<host>.yml`. pinode-01 is on;
k8smaster is declared but **off** until its leg is done.

Run: `ansible-playbook node-vlan-legs.yml --check --diff`, then `--limit <node>`.
Also runs as a step in `day0-infra-build.yml` (no-op where not opted in).

Does NOT touch `prep_prerequisites`' `backend-vlan` task, which still carries the
pre-VLAN20 `backend_vlan_ip` (192.168.1.10/27) and must not be run on k8smaster
until reconciled.

Uses `community.general.nmcli` for all configuration, so check mode and `--diff`
work and only the named properties are compared. The only `command` calls are
the two activations no module offers (`nmcli device reapply`,
`nmcli connection up`), each run only when the module reported a change.
First `--check --diff` against k8smaster showed real drift: `ipv4.ignore-auto-dns`
is `no` live vs `yes` in code (harmless on a static profile; fixed on its next
real run).

Not yet covered here (planned, pinode-01 first): sshd `ListenAddress` limited to
the Trusted address, and the host firewall table guarding the VLAN 40 leg.
