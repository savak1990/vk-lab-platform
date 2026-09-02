#!/usr/bin/env bash
# Creates the State layer's bucket. Idempotent: safe to re-run.
# BUCKET/PROJECT_REGION must match terraform/live/root.hcl's locals if ever changed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$REPO_ROOT/terraform/live/state"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
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

if aws s3api head-bucket --bucket "$BUCKET" --region "$PROJECT_REGION" 2>/dev/null; then
  echo "State bucket s3://$BUCKET already exists - applying terraform/live/state normally."
  terragrunt apply -auto-approve -input=false
  exit 0
fi

echo "State bucket does not exist yet - bootstrapping in two phases."
echo "Phase 1: temporary local backend, so this unit's own state has somewhere to live before the bucket exists."

# A cache left over from an earlier run (different backend config, a prior
# attempt against a different PROJECT_NAME/PROJECT_REGION, etc.) bakes its old
# backend into the cached working directory, which then makes `terraform
# init` refuse to proceed here ("Backend configuration changed"). Clear it
# unconditionally so phase 1 always starts from a clean local state.
rm -rf .terragrunt-cache terraform.tfstate terraform.tfstate.backup

cp terragrunt.hcl terragrunt.hcl.orig
# If phase 1 is interrupted (Ctrl-C) before phase 2 restores the original
# file, restore it immediately rather than leaving terragrunt.hcl silently
# diverged from what's committed for the next run to stumble into.
trap 'if [ -f terragrunt.hcl.orig ]; then mv -f terragrunt.hcl.orig terragrunt.hcl; fi' EXIT

cat >> terragrunt.hcl <<'EOF'

# --- state-up.sh: temporary local-backend override, removed automatically after phase 2 ---
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

echo "Verifying: terraform/live/state should now report no changes."
terragrunt plan -input=false

echo "State layer bootstrapped: s3://$BUCKET, key state/terraform.tfstate."
