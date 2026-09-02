#!/usr/bin/env bash
# Creates the Account layer's own dedicated state bucket - never the same
# bucket as any project's own ${PROJECT_NAME}-tf-state, so a project's
# bootstrap-down destroying its own bucket can never orphan the shared
# lab-role/kms/github-oidc/eks-access-identity units' Terraform state.
# Named from the repo owner, not PROJECT_NAME (see terraform/live/root.hcl's
# account_state_bucket local). Idempotent: safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$REPO_ROOT/terraform/live/account-state"
GITHUB_REPO="${GITHUB_REPO:-savak1990/vk-lab-platform}"
GITHUB_REPO_OWNER="${GITHUB_REPO%%/*}"
BUCKET="${GITHUB_REPO_OWNER}-account-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

cd "$UNIT_DIR"

# A leftover terragrunt.hcl.orig means a previous run was interrupted
# mid-phase-1, before it could restore the committed config. Recover before
# doing anything else, rather than silently applying against the still
# locally-backed config the next time this script runs.
if [ -f terragrunt.hcl.orig ]; then
  echo "Found terragrunt.hcl.orig from an interrupted previous run - recovering."
  mv terragrunt.hcl.orig terragrunt.hcl
  rm -rf .terragrunt-cache terraform.tfstate terraform.tfstate.backup
fi

if aws s3api head-bucket --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION" 2>/dev/null; then
  echo "Account state bucket s3://$BUCKET already exists - applying terraform/live/account/state normally."
  terragrunt apply -auto-approve -input=false
  exit 0
fi

echo "Account state bucket does not exist yet - bootstrapping in two phases."
echo "Phase 1: temporary local backend, so this unit's own state has somewhere to live before the bucket exists."

rm -rf .terragrunt-cache terraform.tfstate terraform.tfstate.backup

cp terragrunt.hcl terragrunt.hcl.orig
trap 'if [ -f terragrunt.hcl.orig ]; then mv -f terragrunt.hcl.orig terragrunt.hcl; fi' EXIT

cat >> terragrunt.hcl <<'EOF'

# --- account-state-up.sh: temporary local-backend override, removed automatically after phase 2 ---
remote_state {
  backend = "local"
  config = {
    path = "terraform.tfstate"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
EOF

terragrunt init -input=false
terragrunt apply -auto-approve -input=false

echo "Bucket created. Phase 2: migrating this unit's state into the bucket it just created."

mv terragrunt.hcl.orig terragrunt.hcl
trap - EXIT
terragrunt init -input=false -migrate-state -force-copy

rm -rf .terragrunt-cache terraform.tfstate terraform.tfstate.backup

echo "Verifying: terraform/live/account-state should now report no changes."
terragrunt plan -input=false

echo "Account state layer bootstrapped: s3://$BUCKET, key account-state/terraform.tfstate."
