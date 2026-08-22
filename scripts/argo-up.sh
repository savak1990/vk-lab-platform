#!/usr/bin/env bash
# Installs Argo CD and the root ("app-of-apps") Application onto the
# disposable EKS cluster. A script, not Terraform (ADR 0012) - Argo's own
# bootstrap only needs to run after EKS exists, and terraform-provider-helm
# can't reliably wait through Argo's finalizer-gated cascade on the way
# down, so both directions use the same non-Terraform mechanism.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
REGION="${REGION:-eu-west-1}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.4.0}"
TARGET_REVISION="${TARGET_REVISION:-main}"
REPO_URL="${REPO_URL:-https://github.com/savak1990/vk-lab-platform}"

eks_output() {
  terragrunt output -raw "$1" --terragrunt-working-dir "$REPO_ROOT/terraform/live/disposable/eks"
}

volume_output() {
  terragrunt output -raw "$1" --terragrunt-working-dir "$REPO_ROOT/terraform/live/persistent/postgres-volume"
}

CLUSTER_NAME="$(eks_output cluster_name)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null
kubectl config set-context --current --namespace=default >/dev/null

VOLUME_ID="$(volume_output volume_id)"
VOLUME_AZ="$(volume_output availability_zone)"
VOLUME_SIZE_GB="$(volume_output size_gb)"

ADMIN_PASSWORD_BCRYPT_HASH_PATH="$REPO_ROOT/secrets/${PROJECT_NAME}/argocd-admin-password.bcrypt"
ADMIN_PASSWORD_BCRYPT_HASH="$(tr -d '[:space:]' < "$ADMIN_PASSWORD_BCRYPT_HASH_PATH")"

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd --create-namespace \
  --set server.service.type=ClusterIP \
  --set configs.secret.argocdServerAdminPassword="$ADMIN_PASSWORD_BCRYPT_HASH" \
  --set configs.secret.argocdServerAdminPasswordMtime="2026-08-20T00:00:00Z" \
  --wait

# No --wait here: the root Application's own health depends on everything
# beneath it in gitops/ reconciling, which can take much longer than a
# helm install timeout is meant to bound. `make up`'s later health check
# (spec 014) is what actually waits for the platform to become healthy.
helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
  --namespace argocd \
  --set target=aws \
  --set project="$PROJECT_NAME" \
  --set repoURL="$REPO_URL" \
  --set targetRevision="$TARGET_REVISION" \
  --set postgres.existingVolumeHandle="$VOLUME_ID" \
  --set postgres.existingVolumeAz="$VOLUME_AZ" \
  --set postgres.existingVolumeSize="${VOLUME_SIZE_GB}Gi"
