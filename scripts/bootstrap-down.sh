#!/usr/bin/env bash
# Destroys Bootstrap-lifecycle resources (the secrets KMS key). Never
# touches the state bucket itself. Guarded: refuses if Persistent or
# Disposable state exists; confirmation is terragrunt's own interactive
# destroy prompt below, not a separate custom one.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

echo "Checking for Persistent/Disposable state in s3://$STATE_BUCKET ..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Checks actual resource counts inside each state file, not just whether
# the key exists - a destroyed stack's (now-empty) state file is never
# deleted, so a plain existence check would refuse forever after the
# first apply. Command substitution assignment is a plain statement, not
# an `if` condition, so `set -e` aborts here (fails closed) if the aws
# call itself errors, instead of silently treating a failed check as "ok".
for prefix in persistent disposable; do
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
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

echo "This destroys the Bootstrap-lifecycle stack: the secrets KMS key (not the state bucket)."
echo "This is expected to run essentially never."

cd "$REPO_ROOT/terraform/live/bootstrap"

# If PROJECT_NAME/REGION differs from whatever this unit's .terragrunt-cache
# was last built against, terraform will refuse with "Backend configuration
# has changed" - run `make clear-cache` first in that case.
terragrunt run --all destroy

# Only after the KMS key is actually gone: its secrets/$PROJECT_NAME/*.enc
# files are now permanently undecryptable ciphertext, so delete them from
# the working tree. Scoped to this PROJECT_NAME only - never a
# secrets/**/*.enc glob, since a different PROJECT_NAME's secrets are
# encrypted under a different KMS key and must survive. This is not
# history scrubbing (old ciphertext remains in git history); it just
# tidies the working tree to match the key's destruction. Never commits on
# its own - the operator commits the deletion themselves.
if [ -d "$REPO_ROOT/secrets/$PROJECT_NAME" ]; then
  find "$REPO_ROOT/secrets/$PROJECT_NAME" -maxdepth 1 -name '*.enc' -print -delete
  echo "Deleted secrets/$PROJECT_NAME/*.enc (KMS key alias/${PROJECT_NAME}-secrets destroyed - commit this deletion)."
fi
