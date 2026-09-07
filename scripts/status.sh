#!/usr/bin/env bash
# Reports which lifecycle layers currently have resources in their
# Terraform state. Purely informational - always exits 0. Checks actual
# resource counts inside each state file, not just whether the (possibly
# emptied-by-destroy) file exists.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$LAB_REGION" >/dev/null 2>&1; then
  echo "state:        absent   (run: make state-up)"
  echo "bootstrap:    unknown  (state layer missing)"
  echo "persistent:   unknown  (state layer missing)"
  echo "cluster:      unknown  (state layer missing)"
  echo "argo:         unknown  (state layer missing)"
  exit 0
fi

echo "state:        present  (s3://$BUCKET)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for prefix in bootstrap persistent persistent-civo cluster cluster-civo; do
  label="$prefix"

  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix/" --region "$LAB_REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  if [ -z "$keys" ] || [ "$keys" = "None" ]; then
    printf '%-13s no data  (never applied)\n' "$label:"
    continue
  fi

  total=0
  for key in $keys; do
    aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$LAB_REGION" "$TMP_DIR/state.json" >/dev/null
    count=$(jq '.resources | length' "$TMP_DIR/state.json")
    total=$((total + count))
  done

  if [ "$total" -gt 0 ]; then
    printf '%-13s present  (%s resource(s) under %s/)\n' "$label:" "$total" "$prefix"
  else
    printf '%-13s absent   (destroyed)\n' "$label:"
  fi
done

# Only attempted if the disposable EKS cluster actually has Terraform state
# to read a cluster_name from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/argo-state.sh"
if [ "${PROVIDER:-aws}" = "civo" ]; then
  CLUSTER_NAME="$(terragrunt --working-dir "$REPO_ROOT/terraform/live/cluster-civo/k8s" output -raw cluster_name 2>/dev/null || true)"
else
  CLUSTER_NAME="$(terragrunt --working-dir "$REPO_ROOT/terraform/live/cluster/eks" output -raw cluster_name 2>/dev/null || true)"
fi

if [ -z "$CLUSTER_NAME" ]; then
  printf '%-13s unknown  (cluster not up)\n' "argo:"
else
  ARGO_ACCESS_ROLE_ARN="$(argo_access_role_arn)"
  printf '%-13s %s\n' "argo:" "$(argo_state "$CLUSTER_NAME" "$(mktemp)")"
fi
