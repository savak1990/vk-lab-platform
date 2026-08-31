#!/usr/bin/env bash
# Implements `make cluster-down`: destroys Disposable-lifecycle resources.
# Refuses to run if Argo CD's
# root Application still exists on a reachable cluster - that means
# `make argo-down` hasn't completed, and proceeding anyway is what causes
# Karpenter's orphaned EC2 instances to block the node security group's
# destroy with DependencyViolation (ADR 0012, spec 006-1). Proceeds
# unconditionally if the cluster is unreachable - there's nothing to check
# against, and a prior interrupted destroy must stay resumable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-eu-west-1}"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"

if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  if kubectl get application root -n argocd >/dev/null 2>&1; then
    echo "Argo CD's root Application still exists - run 'make argo-down' first." >&2
    exit 1
  fi
else
  # Proceeding here (rather than refusing, as above) is deliberate - see the
  # file header. But it means any Karpenter-owned instance not yet drained
  # when the cluster went unreachable is now permanently un-drainable, and
  # will surface later as a DependencyViolation on the node security group's
  # destroy. Log it now so that failure isn't a surprise several minutes in.
  STRAY="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${PROJECT_NAME}-eks" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$STRAY" ] && [ "$STRAY" != "None" ]; then
    echo "CLUSTER-DOWN: WARNING - cluster unreachable but instance(s) tagged for it still exist: $STRAY" >&2
    echo "CLUSTER-DOWN: proceeding anyway (resumable-destroy path) - expect the node security group's destroy to fail until these are terminated." >&2
  fi
fi

cd "$REPO_ROOT/terraform/live/disposable" && terragrunt run --all --non-interactive -- destroy -auto-approve

echo "CLUSTER-DOWN: destroy complete - checking for leaked disposable-lifecycle AWS resources..."
LEAKED_INSTANCES="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
LEAKED_VOLUMES="$(aws ec2 describe-volumes --region "$REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
if { [ -n "$LEAKED_INSTANCES" ] && [ "$LEAKED_INSTANCES" != "None" ]; } || { [ -n "$LEAKED_VOLUMES" ] && [ "$LEAKED_VOLUMES" != "None" ]; }; then
  echo "CLUSTER-DOWN: WARNING - disposable-lifecycle resources still present after destroy:" >&2
  [ -n "$LEAKED_INSTANCES" ] && [ "$LEAKED_INSTANCES" != "None" ] && echo "CLUSTER-DOWN:   instances: $LEAKED_INSTANCES" >&2
  [ -n "$LEAKED_VOLUMES" ] && [ "$LEAKED_VOLUMES" != "None" ] && echo "CLUSTER-DOWN:   volumes: $LEAKED_VOLUMES" >&2
else
  echo "CLUSTER-DOWN: no leaked disposable-lifecycle instances or available volumes found."
fi
