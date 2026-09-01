#!/usr/bin/env bash
# Destroys the Account layer's own dedicated state bucket: permanently
# deletes it (all versions + delete markers, then the bucket) via raw AWS
# API calls, not `terraform destroy` - Terraform cannot cleanly destroy the
# bucket holding its own state (the final state-write during that destroy
# fails once the bucket is gone). Called as the last phase of
# scripts/account-down.sh, after the account/ units themselves are destroyed.
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-savak1990/vk-lab-platform}"
GITHUB_REPO_OWNER="${GITHUB_REPO%%/*}"
BUCKET="${GITHUB_REPO_OWNER}-account-tf-state"
ACCOUNT_MAIN_REGION="${ACCOUNT_MAIN_REGION:-eu-west-1}"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION" 2>/dev/null; then
  echo "s3://$BUCKET does not exist. Nothing to do."
  exit 0
fi

echo "Checking that this bucket's only remaining state is the account-state unit's own ..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Same reasoning as state-down.sh: counts actual resources inside each state
# file, not just key existence - a destroyed stack's now-empty state file is
# never deleted. "account" is the only other prefix that can ever exist in
# this bucket (account-down.sh's own terragrunt destroy should have already
# emptied it); refuse rather than assume if it hasn't.
keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "account/" --region "$ACCOUNT_MAIN_REGION" \
  --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

total=0
if [ -n "$keys" ] && [ "$keys" != "None" ]; then
  for key in $keys; do
    aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$ACCOUNT_MAIN_REGION" "$TMP_DIR/state.json" >/dev/null
    count=$(jq '.resources | length' "$TMP_DIR/state.json")
    total=$((total + count))
  done
fi

if [ "$total" -gt 0 ]; then
  echo "Refusing: account/ state still has $total resource(s). Run account-down's terragrunt destroy first."
  exit 1
fi

echo "Permanently deleting s3://$BUCKET and every version it holds."

aws s3api list-object-versions --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION" \
  --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' > "$TMP_DIR/versions.json"
aws s3api list-object-versions --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION" \
  --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' > "$TMP_DIR/markers.json"

for f in versions markers; do
  total=$(jq '.Objects | length' "$TMP_DIR/$f.json")
  offset=0
  while [ "$offset" -lt "$total" ]; do
    jq -c --argjson offset "$offset" '{Objects: .Objects[$offset:($offset+1000)], Quiet:true}' "$TMP_DIR/$f.json" > "$TMP_DIR/${f}_batch.json"
    if jq -e '.Objects | length > 0' "$TMP_DIR/${f}_batch.json" >/dev/null; then
      aws s3api delete-objects --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION" --delete "file://$TMP_DIR/${f}_batch.json"
    fi
    offset=$((offset + 1000))
  done
done

aws s3api delete-bucket --bucket "$BUCKET" --region "$ACCOUNT_MAIN_REGION"
echo "Deleted s3://$BUCKET."
