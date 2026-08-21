#!/usr/bin/env bash
# Destroys Disposable-lifecycle resources. Karpenter-provisioned EC2
# instances are not tracked in any Terraform state - only Karpenter's own
# controller can delete them cleanly (drain, then terminate via its
# termination finalizer). If the EKS cluster/Karpenter pod disappear first,
# those instances are orphaned; their ENIs then block the node security
# group's destroy with DependencyViolation. So: drain Karpenter's nodes
# first, while its controller is still alive, then destroy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
REGION="${REGION:-eu-west-1}"

# Skip entirely - don't retry, don't hang - if the cluster or Karpenter's
# controller isn't reachable. Deleting a NodePool blocks on Karpenter's own
# termination finalizer; against a dead/unreachable controller that delete
# would never return.
drain_karpenter_nodes() {
  if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    echo "Cluster unreachable - skipping graceful Karpenter node drain." >&2
    return 0
  fi
  if ! kubectl -n kube-system wait --for=condition=Available deployment/karpenter --timeout=10s >/dev/null 2>&1; then
    echo "Karpenter controller not Available - skipping graceful node drain." >&2
    return 0
  fi

  # Argo's selfHeal would otherwise recreate the NodePool we're about to
  # delete out from under it.
  kubectl -n argocd patch application karpenter --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true

  echo "Deleting Karpenter NodePools (blocks until nodes drain and terminate)..."
  kubectl delete nodepool --all --timeout=300s \
    || echo "NodePool delete did not finish cleanly - continuing to terraform destroy; the EC2 sweep below is the backstop." >&2
}

# Backstop for whatever the graceful drain above missed or skipped
# (controller already dead, delete timed out, run interrupted earlier).
# Scoped to this project's Karpenter-tagged instances only.
sweep_orphaned_karpenter_instances() {
  local ids
  ids=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:ManagedBy,Values=karpenter" \
               "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ -n "$ids" ] && [ "$ids" != "None" ]; then
    echo "Terminating orphaned Karpenter instance(s): $ids" >&2
    aws ec2 terminate-instances --region "$REGION" --instance-ids $ids >/dev/null
    echo "$ids"
  fi
}

wait_for_instances_terminated() {
  local ids="$*"
  [ -z "$ids" ] && return 0
  echo "Waiting for terminated instance(s) to release their ENIs: $ids" >&2
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids $ids || true
}

drain_karpenter_nodes

# terragrunt destroy can fail here precisely because of the orphaned
# instances the sweep below exists to clean up - so the sweep must run
# even when destroy fails, not only on success, or it never fires in the
# one case it's for. Retry once after sweeping.
if ! (cd "$REPO_ROOT/terraform/live/disposable" && terragrunt run --all destroy --non-interactive); then
  echo "terragrunt destroy failed - sweeping orphaned Karpenter instances and retrying once..." >&2
  ids="$(sweep_orphaned_karpenter_instances)"
  wait_for_instances_terminated "$ids"
  cd "$REPO_ROOT/terraform/live/disposable" && terragrunt run --all destroy --non-interactive
else
  sweep_orphaned_karpenter_instances >/dev/null
fi
