#!/usr/bin/env bash
# Destroys Bootstrap-lifecycle resources for this PROJECT_NAME: the lab DNS
# zone/delegation + ACM cert, then this project's own state bucket. Never
# touches the shared account-global lab-role/kms (those are account-down's
# job, not this project's). Guarded: refuses if Persistent or Disposable
# state exists, and requires CONFIRM_DESTROY to match PROJECT_NAME exactly -
# applies uniformly to every project, including vk-lab-platform, since the
# shared role has no per-project ARN scoping to fall back on.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/confirm-destroy.sh"

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

confirm_destroy "$PROJECT_NAME"

echo "Checking for Persistent/Disposable state in s3://$STATE_BUCKET ..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Checks actual resource counts inside each state file, not just whether
# the key exists - a destroyed stack's (now-empty) state file is never
# deleted, so a plain existence check would refuse forever after the
# first apply. Command substitution assignment is a plain statement, not
# an `if` condition, so `set -e` aborts here (fails closed) if the aws
# call itself errors, instead of silently treating a failed check as "ok".
for prefix in persistent cluster; do
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  keys=$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "$prefix/" --region "$PROJECT_REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  total=0
  if [ -n "$keys" ] && [ "$keys" != "None" ]; then
    for key in $keys; do
      aws s3api get-object --bucket "$STATE_BUCKET" --key "$key" --region "$PROJECT_REGION" "$TMP_DIR/state.json" >/dev/null
      count=$(jq '.resources | length' "$TMP_DIR/state.json")
      total=$((total + count))
    done
  fi

  if [ "$total" -gt 0 ]; then
    echo "Refusing: $prefix state still has $total resource(s) under $prefix/. Tear that down first."
    exit 1
  fi
done

echo "Destroying Bootstrap-lifecycle stack for $PROJECT_NAME: Route53 zone + ACM cert."

cd "$REPO_ROOT/terraform/live/bootstrap"

# If PROJECT_NAME/PROJECT_REGION differs from whatever this unit's .terragrunt-cache
# was last built against, terraform will refuse with "Backend configuration
# has changed" - run `make clear-cache` first in that case.
#
# -auto-approve skips Terraform's own interactive "yes" prompt so this runs
# unattended (--non-interactive alone doesn't suppress it, confirmed empirically).
terragrunt run --all --non-interactive -- destroy -auto-approve

# This project's own state bucket, via raw AWS API - same self-reference
# constraint as account-state-down.sh: Terraform can't destroy the bucket
# holding its own state.
"$REPO_ROOT/scripts/state-down.sh"
