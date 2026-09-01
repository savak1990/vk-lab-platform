#!/usr/bin/env bash
# Reports which lifecycle layers currently have resources in their
# Terraform state. Purely informational - always exits 0. Checks actual
# resource counts inside each state file, not just whether the (possibly
# emptied-by-destroy) file exists.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
PROJECT_REGION="${PROJECT_REGION:-eu-west-1}"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$PROJECT_REGION" >/dev/null 2>&1; then
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

for prefix in bootstrap persistent disposable; do
  label="$prefix"
  [ "$prefix" = "disposable" ] && label="cluster"

  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix/" --region "$PROJECT_REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  if [ -z "$keys" ] || [ "$keys" = "None" ]; then
    printf '%-13s no data  (never applied)\n' "$label:"
    continue
  fi

  total=0
  for key in $keys; do
    aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$PROJECT_REGION" "$TMP_DIR/state.json" >/dev/null
    count=$(jq '.resources | length' "$TMP_DIR/state.json")
    total=$((total + count))
  done

  if [ "$total" -gt 0 ]; then
    printf '%-13s present  (%s resource(s) under %s/)\n' "$label:" "$total" "$prefix"
  else
    printf '%-13s absent   (destroyed)\n' "$label:"
  fi
done

# Argo CD isn't Terraform-managed (ADR 0012), so its state can't be read
# from Terraform state like the layers above - this checks the live
# cluster instead, and only attempts to if the disposable EKS cluster
# actually has Terraform state to read a cluster_name from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="$(terragrunt --working-dir "$REPO_ROOT/terraform/live/disposable/eks" output -raw cluster_name 2>/dev/null || true)"

if [ -z "$CLUSTER_NAME" ]; then
  printf '%-13s unknown  (cluster not up)\n' "argo:"
elif ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$PROJECT_REGION" --alias "$CLUSTER_NAME" >/dev/null 2>&1 \
  || ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  printf '%-13s unknown  (cluster unreachable)\n' "argo:"
elif ! kubectl get application root -n argocd >/dev/null 2>&1; then
  printf '%-13s absent   (not installed, or torn down by argo-down)\n' "argo:"
else
  SYNC_HEALTH="$(kubectl get application root -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  APP_COUNT="$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  printf '%-13s present  (root %s, %s Application(s) managed)\n' "argo:" "${SYNC_HEALTH:-unknown}" "$APP_COUNT"
fi
