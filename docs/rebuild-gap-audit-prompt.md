# Follow-up prompt: close the rebuild gaps

Paste this into a future Claude Code session (run from `day0-infra-build/`) when
ready to act on the findings in `docs/rebuild-gap-audit.md`.

---

Read `docs/rebuild-gap-audit.md` in this repo — it's a gap audit of whether
`day0-infra-build` can rebuild the cluster from code alone with no manual/tribal
steps. Fix the Critical and High items:

1. **k3s advertise-address/tls-san** — add the `advertise-address: 192.168.1.10`
   and `tls-san: [192.168.1.10]` lines to the config.yaml write in
   `roles/install_required_software/tasks/post_install.yml` (currently it only
   sets `write-kubeconfig-mode`), so the master comes up with the correct
   management-NIC advertise address on a fresh install instead of needing the
   live manual fix from `pi-1-inventory.md` §13b.

2. **Sealed-secrets key restore** — add an Ansible task (new role or extend
   `apply_bootstrap`) that, if a backed-up key exists under
   `credentials/sealed-secrets-key-*.yaml`, applies it to `kube-system` *before*
   ArgoCD's `sealed-secrets` Application syncs the fresh controller — so the
   restored controller reuses the old key instead of generating a new one and
   orphaning every existing `SealedSecret` in `day1-foundation`/`day2-services`.
   Confirm ordering via `sync-wave` annotations if needed.

3. **Worker k3s agent join** — decide and implement how a worker's
   `/etc/rancher/k3s/config.yaml` (server URL, join token, `node-ip`) gets
   written and the k3s agent installed, without depending on a pre-built golden
   SD card. This likely belongs in `roles/nfs_netboot/tasks/add_node.yml` or a
   new task, writing into the per-node overlay
   (`{{ nfs_cluster_path }}/pinode-<mac_suffix>/etc/rancher/k3s/config.yaml`)
   the same way `setup_rsyslog_overlay.yml` does for rsyslog.

4. **Resolve the two netboot pipelines** — decide whether
   `day1-prep-netboot.yml` + `prep_rootfs`/`prep_kernel`/`publish_nfs_os` is
   still intended to replace the SD-card golden-image import in `nfs_netboot`,
   or should be deleted as abandoned. If keeping it, wire it into
   `rebuild-runbook.md`; if not, remove the role/playbook and README references.

After each fix, update `docs/pi-1-inventory.md` and `docs/rebuild-runbook.md` so
they stay in sync with the code, and cross out the closed item in
`docs/rebuild-gap-audit.md` (or delete the audit file once everything in it is
resolved).

Do not touch the two already-tracked, lower-severity items (pause-image
pre-seeding, QNAP NAS export automation) — those are separately tracked in
`BACKLOG.md`.
