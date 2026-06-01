# day0-infra-build Backlog

Tracks outstanding work for the pi-lab infrastructure build-out.
Items move left to right: **Icebox → Todo → In Progress → Done**

---

## In Progress

_Nothing currently in flight._

---

## Todo

### Fix: runbook playbook commands still include `-i inventory/hosts`
`docs/rebuild-runbook.md` steps 3 and 4 still pass `-i inventory/hosts` but `ansible.cfg` now sets the inventory. Commands will still work (flag overrides cfg) but it's misleading and should be cleaned up.
- **File:** `docs/rebuild-runbook.md` lines ~64, ~87

### Fix: `git_org: your-org-name` placeholder in day0_bootstrap.yml
Stale placeholder that gets silently overridden by `variables/common/git.yml` at runtime so nothing breaks, but it's confusing to anyone reading the file.
- **File:** `variables/play/day0_bootstrap.yml` line 2

### Fix: inventory §6 kubeseal listed as "version unknown"
kubeseal is actually pinned to v0.27.1 in `roles/install_required_software/tasks/install_required_software_curl.yml`. The inventory doc is stale.
- **File:** `docs/pi-1-inventory.md` §6

### Fix: remove stale k3s config.yaml gap from inventory §9
"No k3s config.yaml" is listed as a non-blocker gap but it is intentional — latest k3s with defaults is the desired state. Should be removed from the gaps table and noted as a deliberate choice.
- **File:** `docs/pi-1-inventory.md` §9

---

## Icebox

### Feature: 1Password integration for credential population
Currently `credentials/git-pat/token.txt` and `credentials/wifi/{ssid,psk}` are populated manually. A `populate_credentials` role using `community.general.onepassword` lookup + `op` CLI would fetch secrets from 1Password on first run (or on `--tags rotate_git_token` / `--tags change_wifi`). Files are the working copy; 1Password is source of truth. Needs `op` CLI installed on the Pi and `eval $(op signin)` or `OP_SERVICE_ACCOUNT_TOKEN` set before running.

### Feature: QNAP NAS syslog-archive NFS export automation
Currently a manual SSH step into valinor-m (192.168.1.30) to add `syslog-archive` to all sections of `/etc/config/nfssetting` and restart NFS. Could be automated via an Ansible task using `raw` or `ssh` against the QNAP. Low urgency — log-archiver CronJob fails silently until this is done and disk space on the Pi is not a concern at current OS footprint.
- **Details:** `docs/rebuild-runbook.md` §5, `docs/pi-1-inventory.md` §9 Fix 7

### Feature: pin k3s version
Currently `get.k3s.io` installs latest stable. Intentional for now. Revisit if a bad release causes a broken rebuild — at that point add `INSTALL_K3S_VERSION` to the install task.
- **File:** `roles/install_required_software/tasks/install_required_software_curl.yml`

### Feature: Cloudflare Tunnel
Not currently deployed. Not found on host or in k8s workloads. No action needed until a use case is identified.

### Chore: verify kubeseal v0.27.1 matches sealed-secrets-controller version
Before next rebuild, confirm `kubeseal` CLI version matches the `sealed-secrets-controller` image version running in `kube-system`. A mismatch causes `kubeseal` to produce secrets the controller can't decrypt.
- **Check:** `kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'`
