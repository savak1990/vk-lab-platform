#!/usr/bin/env bash
# Fails fast if the Persistent layer hasn't been applied yet. Intended for
# spec 014's `make up` to call before creating any Disposable resource -
# not wired into any target yet.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "persistent/" --region "$REGION" \
  --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

total=0
# An empty prefix makes list-objects-v2's JMESPath filter evaluate against
# null, which --output text renders as the literal string "None" - not
# empty - so this must be checked explicitly.
if [ -n "$keys" ] && [ "$keys" != "None" ]; then
  for key in $keys; do
    aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$REGION" "$TMP_DIR/state.json" >/dev/null
    count=$(jq '.resources | length' "$TMP_DIR/state.json")
    total=$((total + count))
  done
fi

if [ "$total" -eq 0 ]; then
  echo "Persistent-lifecycle resources not found under persistent/ in s3://$BUCKET. Run 'make persistent-up' first." >&2
  exit 1
fi
