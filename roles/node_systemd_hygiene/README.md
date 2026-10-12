# node_systemd_hygiene

Clears first-boot and network leftovers that leave systemd `starting` or
`degraded` (written 2026-10-12, found on pinode-01 after 13+ days stuck).

- **Raspberry Pi first-boot dialog.** `userconfig.service` waits forever on
  /dev/tty8, which holds `multi-user.target`, `cloud-final` and the apt timers
  in "start waiting". The role stops it and purges `userconf-pi` (only that
  package; `autoremove` is off). This also removes the "SSH may not work until
  a valid user has been set up" banner.
- **systemd-networkd.** NetworkManager owns the network on both nodes and no
  `.network` files exist, so networkd and its wait-online unit only fail. Stopped,
  disabled and masked, but only after asserting NetworkManager is running and
  `networkctl list` shows no managed link.
- **cloud-init.** There is no datasource; its stages hang (pinode-01) or fail
  (k8smaster). `/etc/cloud/cloud-init.disabled` is the documented off switch
  (takes effect at the next boot). Netplan profiles on k8smaster are NOT
  cloud-init's and are not touched.
- Waits for `systemctl is-system-running` to be `running` or `degraded`
  (skipped in check mode). `degraded` is accepted because pinode-01 still has
  the separate `mnt-backup.mount` failure, which this role deliberately does
  not hide.

Opt in per host: `node_hygiene_enabled: true` in `variables/cli/host_vars/<host>.yml`.
Options: `node_hygiene` in `variables/play/node_network.yml`.

Run alone: `ansible-playbook node-vlan-legs.yml --tags node_systemd_hygiene --check --diff`.
Also runs from `day0-infra-build.yml` (no-op where not opted in).
