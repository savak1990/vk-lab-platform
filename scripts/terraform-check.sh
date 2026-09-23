#!/usr/bin/env bash
# Validates the Terraform layer: fmt across the tree, then `terraform validate`
# in every module and `terragrunt validate` in every live unit that can run
# without a backend. Needs no credentials and reaches no cloud - every init
# runs with -backend=false.
set -euo pipefail

# Absolute, and resolved before the cd below moves the ground under a relative
# $0. The parallel workers are this same script re-invoked.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

# Each directory pays its own provider init, and they do not depend on each
# other, so they run concurrently. 4 matches the CI runner's vCPU count;
# raise it on a bigger machine.
PARALLEL="${PARALLEL:-4}"

# Output is captured and printed as one block per directory. Four concurrent
# validators interleave line by line otherwise, and a failure then cannot be
# attributed to the directory that caused it.
check_one() {
  local kind="$1" dir="$2" out status=0
  out="$(
    {
      cd "$dir" || exit 1
      # if rather than case: bash 3.2, the bash macOS ships, ends a command
      # substitution at the first `)` and reads a case pattern as that.
      if [ "$kind" = module ]; then
        terraform init -backend=false -input=false && terraform validate
      else
        TF_CLI_ARGS_init="-backend=false" terragrunt validate --non-interactive
      fi
    } 2>&1
  )" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '== %s ==\n%s\n' "$dir" "$out"
  else
    printf '== %s == FAILED (exit %s)\n%s\n' "$dir" "$status" "$out"
  fi
  return "$status"
}

# The worker entry point. Re-invoking this script beats exporting a function:
# bash 3.2, which is the bash macOS ships, mangles a multi-line exported
# function body and every worker then dies with a syntax error.
if [ "${1:-}" = "--one" ]; then
  check_one "$2" "$3"
  exit $?
fi

# Units with a `dependency` block are skipped: terragrunt resolves
# `dependency.x.outputs` by running `terraform output -json` directly in the
# dependency's own working directory, which hard-fails without a real
# initialized backend rather than falling back to mock_outputs. Giving this
# check real AWS reachability just to validate HCL would defeat the point.
# Their module code is still covered by the module loop.
LIVE_UNITS=(
  account-state
  account/ahorro-ci-role
  account/eks-access-identity
  account/eks-test-identity
  account/github-oidc
  account/kms
  account/lab-role
  account/root-domain
  bootstrap/route53
  persistent-civo/backups
  persistent-civo/network
  persistent-civo/reserved-ip
  persistent-hetzner/network
  persistent-hetzner/ssh-key
  persistent/backups
  persistent/secrets
  persistent/vpc
  state
)

echo "TERRAFORM-CHECK: terraform fmt -check"
terraform fmt -check -recursive terraform/

# xargs exits 123 when any invocation failed, which -e turns into a failed
# run. Without this the whole point of the check is lost: a parallel loop that
# swallows a validation error looks exactly like a fast one.
echo "TERRAFORM-CHECK: terraform validate in every module, $PARALLEL at a time"
printf '%s\n' terraform/modules/*/ \
  | sed 's:/*$::' \
  | xargs -P "$PARALLEL" -I{} "$SELF" --one module {}

echo "TERRAFORM-CHECK: terragrunt validate in ${#LIVE_UNITS[@]} live units, $PARALLEL at a time"
printf 'terraform/live/%s\n' "${LIVE_UNITS[@]}" \
  | xargs -P "$PARALLEL" -I{} "$SELF" --one unit {}

echo "TERRAFORM-CHECK: the Terraform layer is valid."
