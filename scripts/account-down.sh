#!/usr/bin/env bash
# Destroys account-global resources (the GitHub OIDC provider). Guarded:
# refuses while this project still has state. Confirmation is terragrunt's own
# interactive destroy prompt below, not a separate custom one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

echo "Checking for Bootstrap/Persistent/Disposable state in s3://$STATE_BUCKET ..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Mirrors scripts/bootstrap-down.sh: counts resources inside each state file
# rather than testing key existence, since a destroyed stack's now-empty state
# file is never deleted. The command substitution is a plain statement, not an
# `if` condition, so `set -e` fails closed if the aws call itself errors.
for prefix in bootstrap persistent disposable; do
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate against
  # null, which --output text renders as the literal string "None".
  keys=$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "$prefix/" --region "$REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  total=0
  if [ -n "$keys" ] && [ "$keys" != "None" ]; then
    for key in $keys; do
      aws s3api get-object --bucket "$STATE_BUCKET" --key "$key" --region "$REGION" "$TMP_DIR/state.json" >/dev/null
      count=$(jq '.resources | length' "$TMP_DIR/state.json")
      total=$((total + count))
    done
  fi

  if [ "$total" -gt 0 ]; then
    echo "Refusing: $prefix state still has $total resource(s) under $prefix/. Tear that down first."
    exit 1
  fi
done

# This check only sees PROJECT_NAME's own bucket. Another project or a CI
# environment in the same account may still be relying on the provider, and
# there is no cheap way to enumerate them - hence the warning rather than a
# guard.
echo "This destroys the account-global stack: the GitHub OIDC provider."
echo "It is shared by EVERY project and CI environment in AWS account"
echo "$(aws sts get-caller-identity --query Account --output text) - any of them still using it will fail to authenticate."
echo "This is expected to run essentially never."

cd "$REPO_ROOT/terraform/live/account"

# If PROJECT_NAME/REGION differs from whatever this unit's .terragrunt-cache
# was last built against, terraform will refuse with "Backend configuration
# has changed" - run `make clear-cache` first in that case.
terragrunt run --all destroy
