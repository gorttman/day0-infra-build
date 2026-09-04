# Remediation queue

Numbered, idempotent fixes for findings from the 2026-09-04 cluster audit.
One item per invocation, so the queue can run unattended overnight.

    ./run-next.sh

`run-next.sh` picks the lowest-numbered script with no `state/NN.done`
marker, runs it, appends one line to `remediation.log`, and stops.

Task exit codes:

| code | meaning | marker written | retries |
|------|---------|----------------|---------|
| 0 | done, verified | yes | no |
| 1 | failed, nothing changed | no | yes |
| 2 | blocked on a human decision | no | yes |

Only exit 0 writes a marker, so 1 and 2 are picked up again on the next run.

Scripts must be idempotent: every one starts by checking whether its work
is already done and exits 0 if so. Re-running the whole queue must be safe.

`state/` holds runtime bookkeeping (markers, per-item detail logs) which is
gitignored. The `*.manifest` files are not: they record exactly what item 07
deleted, and that audit trail belongs in the repo.

## Restore dependency

`credentials/ssh/` holds the SSH private keys this cluster needs to reach
the QNAP (`qnap_ansible_ed25519`, referenced by
`variables/cli/group_vars/qnap.yml`), pinode-01, and GitHub. That directory
is gitignored and reaches the QNAP through the nightly `credentials/` rsync
in `roles/qnap_client`.

A rebuild must copy them back to `~/.ssh` with mode 600 before any
QNAP-targeting play will run. Wiring that into `restore.sh` is queue item 6.
