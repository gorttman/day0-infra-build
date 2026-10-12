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

## sshd restricted to the Trusted address (`node_ssh_listen_address`)

sshd on Debian 13 is **socket-activated**, so `ListenAddress` in `sshd_config`
is ignored; the role drops `/etc/systemd/system/ssh.socket.d/10-listen-trusted.conf`
(`ListenStream=<addr>:22`, `FreeBind=true`). `FreeBind` lets the socket bind
before the NIC has the address at boot (Debian's unit has
`RestartPreventExitStatus=255`, so a failed bind would never retry). Rebinding
must **stop ssh.service first**: systemd refuses to restart a socket whose
service is running. Sessions survive (`KillMode=process`). The tasks sit in a
block that rolls back to all addresses if the socket does not come up.
When changing this by hand, arm an independent watchdog first
(`systemd-run --on-active=420 ...` that removes the drop-in and restarts the
socket) and keep a second session open. Cold-boot behaviour has not been
reboot-tested; `FreeBind` was proven on an address the node does not own.

## Host firewall for the leg (`node_iot_guard_enabled`)

`iot-guard.service` loads its own nft table (`inet iot_guard`) from
`/etc/nftables.d/iot-guard.nft`. One hook rule jumps only for traffic entering
on `eth0.40`; everything else is untouched. It is a separate unit because the
stock `/etc/nftables.conf` starts with `flush ruleset` (which would wipe the
kube/MetalLB tables); the unit is ordered after, and `PartOf`, `nftables.service`
so a reload re-adds it. Allow-list (variables/play/node_network.yml): ICMP,
IGMP, established/related, TCP 8097/8927, UDP 5353, and high ports 32768-60999
from the IoT subnet only; drops are rate-limit logged (`iot-guard drop`).
Tested on pinode-01: via the leg, 8097 open, an unlisted port with a live
listener blocked, SSH and kubelet blocked; the same ports on the Trusted address
unaffected; outbound to the Bose still works. The allow-list is a first guess for
AirPlay 2 / Sendspin; tune from the drop log once Music Assistant runs on a
node with the leg.

## Known systemd oddities on pinode-01

systemd there has been stuck in `starting` for 13+ days (the Raspberry Pi
first-boot `userconfig.service` never finishes, so `multi-user.target` and
`cloud-init.target` stay `start waiting`). Two D-Bus calls (`stop ssh.service`,
`daemon-reload`) have timed out once each; ~20 others were fine. Cause not
established, so the systemd tasks here retry 3 times.
