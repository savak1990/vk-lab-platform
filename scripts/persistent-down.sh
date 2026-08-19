#!/usr/bin/env bash
# Destroys Persistent-lifecycle resources: the lab DNS zone (and its
# parent-zone NS delegation record), the ACM certificate, and everything in
# Secrets Manager. Guarded: refuses while Disposable state exists, and
# verifies afterward that every unit's state is actually empty -
# `dependency`-based destroy ordering applies acm/secrets before route53,
# and a partial failure there could otherwise leave the zone (and its
# parent-zone delegation) orphaned while reporting success. Confirmation is
# terragrunt's own interactive destroy prompt below (typing "yes"), not a
# separate custom one - same approach as bootstrap-down.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Checks actual resource counts inside each state file, not just whether
# the key exists - a destroyed stack's (now-empty) state file is never
# deleted, so a plain existence check would refuse forever after the first
# apply. Explicitly checks each aws/jq call's exit status and `return`s
# non-zero on failure - set -e does NOT reliably abort a function invoked
# via command substitution (var=$(func)) the way it aborts a plain
# top-level statement, so an aws failure here must be caught by hand
# rather than trusted to propagate on its own (verified empirically; this
# is not the "plain statement" case bootstrap-down.sh's own comment relies on).
count_resources() {
  local prefix="$1"
  local keys
  if ! keys=$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "$prefix/" --region "$REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text); then
    echo "Failed to list s3://$STATE_BUCKET/$prefix/ - aborting rather than treating this as 'no resources'." >&2
    return 1
  fi

  local total=0
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  if [ -n "$keys" ] && [ "$keys" != "None" ]; then
    local key count
    for key in $keys; do
      if ! aws s3api get-object --bucket "$STATE_BUCKET" --key "$key" --region "$REGION" "$TMP_DIR/state.json" >/dev/null; then
        echo "Failed to read state object $key - aborting rather than treating this as 'no resources'." >&2
        return 1
      fi
      if ! count=$(jq '.resources | length' "$TMP_DIR/state.json"); then
        echo "Failed to parse state object $key - aborting rather than treating this as 'no resources'." >&2
        return 1
      fi
      total=$((total + count))
    done
  fi
  echo "$total"
}

echo "Checking for Disposable state in s3://$STATE_BUCKET ..."

if ! disposable_total=$(count_resources "disposable"); then
  exit 1
fi
if [ "$disposable_total" -gt 0 ]; then
  echo "Refusing: disposable state still has $disposable_total resource(s). Run 'make down' first."
  exit 1
fi

echo "This permanently deletes the lab.<root-domain> DNS zone (and its parent-zone NS"
echo "delegation record), its ACM certificate, and every secret in Secrets Manager."
echo "This is expected to run essentially never."

cd "$REPO_ROOT/terraform/live/persistent"

# If PROJECT_NAME/REGION/SUBDOMAIN differs from whatever this unit's
# .terragrunt-cache was last built against, terraform will refuse with
# "Backend configuration has changed" - run `make clear-cache` first in
# that case. No --non-interactive here: terragrunt's own destroy prompt
# (type "yes") is the confirmation step, not a custom one.
terragrunt run --all destroy

for unit_prefix in persistent/route53 persistent/acm persistent/secrets; do
  if ! remaining=$(count_resources "$unit_prefix"); then
    exit 1
  fi
  if [ "$remaining" -gt 0 ]; then
    echo "Refusing to report success: $unit_prefix still has $remaining resource(s) after destroy." >&2
    exit 1
  fi
done

echo "Persistent-lifecycle resources destroyed."
