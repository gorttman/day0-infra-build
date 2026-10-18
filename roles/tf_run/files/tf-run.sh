#!/bin/bash
# Plan (and optionally apply) one Terraform stack. Provider secrets arrive as
# TF_VAR_* in the environment. Prints PLAN_SHA=<16 hex> of the rendered plan;
# applies only if TF_RUN_DO_APPLY=true AND TF_RUN_APPROVED_PLAN matches it,
# and refuses any destroy unless TF_RUN_ALLOW_DESTROY=true.
set -euo pipefail
cd "$TF_RUN_WORK"
terraform init -input=false -no-color -backend-config="path=${TF_RUN_STATE}" >/dev/null
terraform plan -input=false -no-color -out=tfplan | tee plan.txt

plan_sha=$(terraform show -no-color tfplan | sha256sum | cut -c1-16)
echo "PLAN_SHA=${plan_sha}"

destroy_count=$(sed -n 's/^Plan: .*, \([0-9]\{1,\}\) to destroy\..*/\1/p' plan.txt)
destroy_count=${destroy_count:-0}
if [ "${destroy_count}" -gt 0 ] && [ "${TF_RUN_ALLOW_DESTROY:-false}" != "true" ]; then
  echo "REFUSING TO APPLY: plan would destroy ${destroy_count} resource(s)." >&2
  echo "If intended, re-run with -e ${TF_RUN_STACK}_tf_allow_destroy=true." >&2
  exit 1
fi

if [ "${TF_RUN_DO_APPLY:-false}" != "true" ]; then
  echo "=== PLAN-ONLY RUN - nothing changed ==="
  exit 0
fi

if [ "${TF_RUN_APPROVED_PLAN:-}" != "${plan_sha}" ]; then
  echo "REFUSING TO APPLY: this plan is ${plan_sha}, you approved '${TF_RUN_APPROVED_PLAN:-}'." >&2
  echo "Something changed since you reviewed it. Re-run plan-only and review again." >&2
  exit 1
fi

terraform apply -input=false -no-color tfplan
echo "=== APPLIED ${plan_sha} ==="
