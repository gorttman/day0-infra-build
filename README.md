# Pi-Lab Day-0 Bootstrap

This repo bootstraps the Pi-Lab cluster.

## Flow
1. Ansible installs:
   - Required system packages (curl, git, nfs-utils)
   - k3s via curl
   - Minimal ArgoCD manifests

2. Ansible creates ArgoCD repo secret for `pi-lab-foundation`

3. Ansible applies `apps/bootstrap.yaml`

4. ArgoCD takes over and deploys the **foundation-layer** (MetalLB, Longhorn, ingress-nginx, Sealed Secrets, cert-manager, monitoring and logging) and then the services in `day2-services`.

**Who owns what.** Ansible/Terraform own everything outside the Kubernetes API: hosts, k3s, the QNAP, the UDM, Cloudflare, and ArgoCD itself. ArgoCD does *not* manage its own components; it is installed by Ansible (`apply_bootstrap`, currently v3.2.0), so upgrading Argo means changing that role and re-running it. ArgoCD owns every Kubernetes object from the foundation layer up. (An earlier version of this file said "Argo self-manage"; that was never true.)

## Usage
```bash
ansible-galaxy install -r requirements.yml
ansible-playbook playbooks/day0-bootstrap.yml --tags install_day0
```
