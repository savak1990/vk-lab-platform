#!/usr/bin/env bash
# Destroys the State layer: permanently deletes the Terraform state bucket
# itself (all versions + delete markers, then the bucket). Guarded escape
# hatch for tearing down a whole throwaway/test AWS account, not a normal
# operation and not part of any per-environment lifecycle.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
PROJECT_REGION="${PROJECT_REGION:-eu-west-1}"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$PROJECT_REGION" 2>/dev/null; then
  echo "s3://$BUCKET does not exist. Nothing to do."
  exit 0
fi

echo "Checking for state under every other lifecycle prefix in s3://$BUCKET ..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Checks actual resource counts inside each state file, not just whether
# the key exists - a destroyed stack's (now-empty) state file is never
# deleted, so a plain existence check would refuse forever after the
# first apply. Command substitution assignment is a plain statement, not
# an `if` condition, so `set -e` aborts here (fails closed) if the aws
# call itself errors, instead of silently treating a failed check as "ok".
for prefix in bootstrap persistent disposable ci; do
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix/" --region "$PROJECT_REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  total=0
  if [ -n "$keys" ] && [ "$keys" != "None" ]; then
    for key in $keys; do
      aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$PROJECT_REGION" "$TMP_DIR/state.json" >/dev/null
      count=$(jq '.resources | length' "$TMP_DIR/state.json")
      total=$((total + count))
    done
  fi

  if [ "$total" -gt 0 ]; then
    echo "Refusing: $prefix state still has $total resource(s) under $prefix/. Tear that down first."
    exit 1
  fi
done

echo "Permanently deleting s3://$BUCKET and every version it holds."

aws s3api list-object-versions --bucket "$BUCKET" --region "$PROJECT_REGION" \
  --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > "$TMP_DIR/versions.json"
aws s3api list-object-versions --bucket "$BUCKET" --region "$PROJECT_REGION" \
  --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > "$TMP_DIR/markers.json"

for f in versions markers; do
  jq -c '.Objects[:1000] as $batch | {Objects: $batch, Quiet:true}' "$TMP_DIR/$f.json" > "$TMP_DIR/${f}_del.json"
  total=$(jq '.Objects | length' "$TMP_DIR/$f.json")
  offset=0
  while [ "$offset" -lt "$total" ]; do
    jq -c --argjson offset "$offset" '{Objects: .Objects[$offset:($offset+1000)], Quiet:true}' "$TMP_DIR/$f.json" > "$TMP_DIR/${f}_batch.json"
    if jq -e '.Objects | length > 0' "$TMP_DIR/${f}_batch.json" >/dev/null; then
      aws s3api delete-objects --bucket "$BUCKET" --region "$PROJECT_REGION" --delete "file://$TMP_DIR/${f}_batch.json"
    fi
    offset=$((offset + 1000))
  done
done

aws s3api delete-bucket --bucket "$BUCKET" --region "$PROJECT_REGION"
echo "Deleted s3://$BUCKET."
