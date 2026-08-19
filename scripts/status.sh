#!/usr/bin/env bash
# Reports which lifecycle layers currently have resources in their
# Terraform state. Purely informational - always exits 0. Checks actual
# resource counts inside each state file, not just whether the (possibly
# emptied-by-destroy) file exists. See require-state.sh for the check
# bootstrap-up uses to fail fast when the State layer is missing.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "state:        absent   (run: make state-up)"
  echo "bootstrap:    unknown  (state layer missing)"
  echo "persistent:   unknown  (state layer missing)"
  echo "disposable:   unknown  (state layer missing)"
  exit 0
fi

echo "state:        present  (s3://$BUCKET)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for prefix in bootstrap persistent disposable; do
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix/" --region "$REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  if [ -z "$keys" ] || [ "$keys" = "None" ]; then
    printf '%-13s no data  (never applied)\n' "$prefix:"
    continue
  fi

  total=0
  for key in $keys; do
    aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$REGION" "$TMP_DIR/state.json" >/dev/null
    count=$(jq '.resources | length' "$TMP_DIR/state.json")
    total=$((total + count))
  done

  if [ "$total" -gt 0 ]; then
    printf '%-13s present  (%s resource(s) under %s/)\n' "$prefix:" "$total" "$prefix"
  else
    printf '%-13s absent   (destroyed)\n' "$prefix:"
  fi
done
