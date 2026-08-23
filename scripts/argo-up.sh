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
# Project-scoped so two environments with different PROJECT_NAME values in
# the same region/account never collide on each other's snapshots.
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

eks_output() {
  terragrunt --working-dir "$REPO_ROOT/terraform/live/disposable/eks" output -raw "$1"
}

CLUSTER_NAME="$(eks_output cluster_name)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null
kubectl config set-context --current --namespace=default >/dev/null

# Idempotency guard: if the root Application is already Synced/Healthy,
# there's nothing to do. Beyond avoiding pointless work, this sidesteps a
# real Helm bug on re-run: Argo's own controller takes server-side-apply
# ownership of some Application spec fields (e.g. normalized
# .spec.ignoreDifferences) once it's reconciled the object, and a second
# `helm upgrade --install` on an already-synced root can then fail with
# "Apply failed with 1 conflict" against that field manager.
#
# Safe under the stricter wait below: Argo's health rollup for the CNPG
# Cluster resource already reflects Postgres readiness, not just sync state.
EXISTING_STATUS="$(kubectl get application root -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
if [ "$EXISTING_STATUS" = "Synced/Healthy" ]; then
  echo "ARGO-UP: root Application already Synced/Healthy - nothing to do."
  exit 0
fi

# Discovers the latest Postgres EBS snapshot (if any) before pruning -
# deletion below is async, so discovering after pruning would open a race
# window against a snapshot mid-delete. Terraform has no role here: the
# snapshot is created by the running cluster at teardown time, not at
# apply time, so there's nothing for Terraform state to track (ADR 0013).
# A probe error (creds/network) aborts loudly rather than silently
# falling through to a fresh initdb over a good snapshot.
if ! SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
  --filters "${SNAPSHOT_TAG_FILTERS[@]}" "Name=status,Values=completed" \
  --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
  echo "ARGO-UP: failed to query AWS for existing Postgres snapshots - aborting rather than risking a false 'fresh start'." >&2
  exit 1
fi
RECOVERY_SNAPSHOT_HANDLE="$(echo "$SNAPSHOTS_JSON" | jq -r '.[-1].SnapshotId // ""')"
if [ -n "$RECOVERY_SNAPSHOT_HANDLE" ]; then
  echo "ARGO-UP: found latest Postgres snapshot $RECOVERY_SNAPSHOT_HANDLE - will recover from it."
else
  echo "ARGO-UP: no existing Postgres snapshot found - will bootstrap fresh (initdb)."
fi

# Safety net for an interrupted prior argo-down (the primary enforcement
# point for "keep newest 2" is argo-down.sh itself, right after it creates
# a new snapshot). Re-queried without the status=completed filter, unlike
# the discovery query above - a still-pending snapshot must still count
# toward "newest 2" or this miscounts and prunes the wrong one.
if ! ALL_SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
  --filters "${SNAPSHOT_TAG_FILTERS[@]}" \
  --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
  echo "ARGO-UP: failed to query AWS for Postgres snapshots to prune - aborting." >&2
  exit 1
fi
OLD_SNAPSHOTS="$(echo "$ALL_SNAPSHOTS_JSON" | jq -r '.[:-2][].SnapshotId')"
if [ -n "$OLD_SNAPSHOTS" ]; then
  for snapshot_id in $OLD_SNAPSHOTS; do
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snapshot_id"
    echo "ARGO-UP: pruned old snapshot $snapshot_id"
  done
fi

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
# beneath it in gitops/ reconciling, which can take much longer than a helm
# install timeout is meant to bound. The wait loop below handles that.
helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
  --namespace argocd \
  --set target=aws \
  --set project="$PROJECT_NAME" \
  --set region="$REGION" \
  --set repoURL="$REPO_URL" \
  --set targetRevision="$TARGET_REVISION" \
  --set postgres.recoverySnapshotHandle="$RECOVERY_SNAPSHOT_HANDLE"

# Blocks until root is Synced/Healthy, so a 0 exit means the whole platform
# (including Postgres) is really ready. Only prints a line when the pending
# set changes, to stay readable over a long recovery-from-snapshot bootstrap.
WATCH_SECONDS="${ARGO_UP_WATCH_SECONDS:-600}"
POLL_INTERVAL="${ARGO_UP_POLL_INTERVAL:-5}"
elapsed=0
last_pending=""
overall=""
while [ "$elapsed" -lt "$WATCH_SECONDS" ]; do
  overall="$(kubectl get application root -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  pending="$(kubectl get application root -n argocd \
    -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name}={.status}({.health.status}) {end}' 2>/dev/null || true)"
  if [ "$pending" != "$last_pending" ]; then
    echo "ARGO-UP: root ${overall:-pending} - still reconciling: ${pending:-none}"
    last_pending="$pending"
  fi
  [ "$overall" = "Synced/Healthy" ] && break
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [ "$overall" != "Synced/Healthy" ]; then
  echo "ARGO-UP: timed out after ${WATCH_SECONDS}s waiting for root to become Synced/Healthy - still reconciling: ${last_pending:-none}" >&2
  exit 1
fi
echo "ARGO-UP: root Synced/Healthy - platform ready."
