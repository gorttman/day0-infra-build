# tf_run

Generic Terraform runner for the Cloudflare and UniFi stacks. Called by
`cloudflare_tf_apply` and `unifi_tf_apply`; those roles keep the `.tf` files
and the history, this one does the work.

## Why it runs on the host, not in the cluster

The UniFi stack builds the network k3s needs (VLANs, DHCP, DNS), so it has to
be runnable on day 0 before any cluster exists, and with k3s down. So
Terraform runs on the control host (k8smaster) with a pinned binary. No Job,
no ConfigMap, no Kubernetes API.

## What it does each run

1. Installs the pinned Terraform (`tf_run_version`, checksum-verified).
2. Restores the stack's state from the vaulted copy if the host has none.
3. Copies the `.tf` files to a fresh work dir and runs init + plan.
4. Prints `PLAN_SHA=<16 hex>` (sha256 of the rendered plan).
5. Applies only with `*_tf_do_apply=true` AND `*_tf_approved_plan=<PLAN_SHA>`;
   refuses any destroy without `*_tf_allow_destroy=true`.
6. Refreshes the vaulted state copy if the state changed.

## Where things live

- Provider secrets: `variables/common/tf-secrets.yml` (ansible-vault). Edit
  with `ansible-vault edit variables/common/tf-secrets.yml`.
- Vault password: `credentials/vault_pass` (gitignored; `credentials/` is
  rsynced to the QNAP nightly). Referenced from `ansible.cfg`.
- Live state: `/var/lib/infra-tf/<stack>/terraform.tfstate` (root, 0600).
- Vaulted state copy: `state/<stack>.tfstate.enc` in this repo. Commit it
  after an apply.

## Rebuild

Restore `credentials/` and the repo, run the play: state is decrypted from
`state/`, the plan should be empty. Verified 2026-10-18 by deleting the live
state and re-planning.

## History

Until 2026-10-18 these stacks ran as Jobs in the cluster with state in the
shared Postgres (databases `cloudflare_tf` and `unifi_tf`, left in place,
no longer used). The READMEs in the two stack roles describe that earlier
design where they mention Jobs, Argo or Postgres.
