#!/usr/bin/env bash
# Implements `make cluster-down`: destroys Disposable-lifecycle resources.
# Refuses to run if Argo CD's root Application still exists on a reachable
# cluster - that means `make argo-down` hasn't completed, and proceeding
# anyway is what causes Karpenter's orphaned EC2 instances to block the node
# security group's destroy with DependencyViolation (ADR 0012, spec 006-1).
# Also refuses if the cluster exists but is unreachable: without kubectl
# access there is no way to confirm argo-down's cascade actually ran, and a
# blind terragrunt destroy against a cluster that turns out to still be
# alive orphans whatever Karpenter/aws-load-balancer-controller hadn't
# finished tearing down. If the cluster doesn't exist at all (per the AWS
# API, not kubectl), there's nothing to check - proceed straight to destroy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
CLUSTER_NAME="${PROJECT_NAME}-eks"

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$PROJECT_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$PROJECT_REGION" --alias "$CLUSTER_NAME" \
    --role-arn "$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)" >/dev/null
  kubectl config set-context --current --namespace=default >/dev/null

  if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    echo "CLUSTER-DOWN: ERROR - cluster $CLUSTER_NAME exists but is unreachable via kubectl (cluster-info failed)." >&2
    echo "CLUSTER-DOWN: refusing to run 'terragrunt destroy' blind - argo-down's graceful cascade could not be" >&2
    echo "CLUSTER-DOWN: confirmed, so any Karpenter node or load balancer still alive right now will be orphaned" >&2
    echo "CLUSTER-DOWN: if the control plane is destroyed anyway. Investigate cluster/API-server health before retrying." >&2
    exit 1
  fi

  if kubectl get application root -n argocd >/dev/null 2>&1; then
    echo "Argo CD's root Application still exists - run 'make argo-down' first." >&2
    exit 1
  fi
else
  echo "CLUSTER-DOWN: cluster $CLUSTER_NAME does not exist - skipping kubectl checks, proceeding to terragrunt destroy."
fi

cd "$REPO_ROOT/terraform/live/cluster" && terragrunt run --all --non-interactive -- destroy -auto-approve

echo "CLUSTER-DOWN: destroy complete - checking for leaked disposable-lifecycle AWS resources..."
LEAKED_INSTANCES="$(aws ec2 describe-instances --region "$PROJECT_REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
LEAKED_VOLUMES="$(aws ec2 describe-volumes --region "$PROJECT_REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)"
# NLBs/ENIs/security groups created by aws-load-balancer-controller aren't
# Terraform-tracked, so the destroy above never touches them - tag-based
# lookup is the only way to catch one stranded by the same cluster-already-
# unreachable condition argo-down.sh warns about.
LEAKED_NLBS="$(aws resourcegroupstaggingapi get-resources --region "$PROJECT_REGION" \
  --tag-filters "Key=Project,Values=$PROJECT_NAME" "Key=Lifecycle,Values=disposable" \
  --resource-type-filters elasticloadbalancing:loadbalancer elasticloadbalancing:targetgroup \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"
if { [ -n "$LEAKED_INSTANCES" ] && [ "$LEAKED_INSTANCES" != "None" ]; } || { [ -n "$LEAKED_VOLUMES" ] && [ "$LEAKED_VOLUMES" != "None" ]; } || { [ -n "$LEAKED_NLBS" ] && [ "$LEAKED_NLBS" != "None" ]; }; then
  echo "CLUSTER-DOWN: WARNING - disposable-lifecycle resources still present after destroy:" >&2
  [ -n "$LEAKED_INSTANCES" ] && [ "$LEAKED_INSTANCES" != "None" ] && echo "CLUSTER-DOWN:   instances: $LEAKED_INSTANCES" >&2
  [ -n "$LEAKED_VOLUMES" ] && [ "$LEAKED_VOLUMES" != "None" ] && echo "CLUSTER-DOWN:   volumes: $LEAKED_VOLUMES" >&2
  [ -n "$LEAKED_NLBS" ] && [ "$LEAKED_NLBS" != "None" ] && echo "CLUSTER-DOWN:   load balancers/target groups: $LEAKED_NLBS (an NLB's security groups are also leaked - check DNS records in the lab zone too)" >&2
else
  echo "CLUSTER-DOWN: no leaked disposable-lifecycle instances or available volumes found."
fi
