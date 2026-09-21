#!/usr/bin/env bash
# Creates the State layer's bucket. Idempotent: safe to re-run.
# BUCKET must match terraform/live/root.hcl's locals if ever changed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR="$REPO_ROOT/terraform/live/state"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
# shellcheck source=lib/catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/catalog.sh"
BUCKET="${PROJECT_NAME}-${LAB_PROVIDER_REGION}-tf-state"

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

# An interrupted phase 1 leaves this unit's cache initialized against the
# local backend, which makes the next apply fail with "Backend type changed".
if grep -rqs 'backend "local"' .terragrunt-cache; then
  echo "Found a local-backend cache from an interrupted previous run - clearing it."
  rm -rf .terragrunt-cache
fi

# Probed separately because head-bucket reports missing credentials and a
# missing bucket the same way, and treating the former as "no bucket" sends
# this script down the two-phase path against a bucket that already exists.
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "No usable AWS credentials - set AWS_PROFILE or log in, then re-run." >&2
  exit 1
fi

# Changing REGION migrates nothing. The bucket name carries the region, so a
# new region means a new bucket while the old platform keeps billing,
# invisible to this project's state. Candidates come from the catalogue, not
# a name prefix, which would false-match a longer project name.
for candidate_region in $(catalog_regions "$PROVIDER"); do
  candidate_lower="$(catalog_lower "$candidate_region")"
  [ "$candidate_lower" = "$LAB_PROVIDER_REGION" ] && continue
  other_bucket="${PROJECT_NAME}-${candidate_lower}-tf-state"
  aws s3api head-bucket --bucket "$other_bucket" --region "$LAB_REGION" >/dev/null 2>&1 || continue

  other_count="$(aws s3api list-objects-v2 --bucket "$other_bucket" --region "$LAB_REGION" \
    --query 'length(Contents)' --output text 2>/dev/null || echo 0)"
  [ "$other_count" = "None" ] && other_count=0
  [ "$other_count" -gt 0 ] || continue

  {
    echo "Refusing: this project already exists in $candidate_region."
    echo "  s3://$other_bucket still holds $other_count object(s)."
    echo "Changing REGION does not move a platform - it would build a second one"
    echo "and leave the first running and billing, invisible to the new state."
    echo "Destroy the existing one first:"
    echo "  REGION=$candidate_region CONFIRM_DESTROY=$PROJECT_NAME make full-down"
  } >&2
  exit 1
done

head_error="$(aws s3api head-bucket --bucket "$BUCKET" --region "$LAB_REGION" 2>&1)" && head_rc=0 || head_rc=$?

if [ "$head_rc" -eq 0 ]; then
  echo "State bucket s3://$BUCKET already exists - applying terraform/live/state normally."
  terragrunt apply -auto-approve -input=false
  exit 0
fi

if ! printf '%s' "$head_error" | grep -q '(404)'; then
  echo "Could not determine whether s3://$BUCKET exists - refusing to bootstrap over it." >&2
  echo "$head_error" >&2
  exit 1
fi

echo "State bucket does not exist yet - bootstrapping in two phases."
echo "Phase 1: temporary local backend, so this unit's own state has somewhere to live before the bucket exists."

# A cache left over from an earlier run (different backend config, a prior
# attempt against a different PROJECT_NAME, etc.) bakes its old
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
