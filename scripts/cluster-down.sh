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
#
# The post-destroy sweep below deletes anything it finds and still exits
# non-zero (ADR 0026, amending ADR 0012's "a sweep is a sign the cascade
# didn't finish" stance): a leaked resource costs money for as long as it
# survives, so it is removed immediately rather than left for a human to
# notice a warning - but the non-zero exit means the underlying cascade bug
# still surfaces as a CI failure instead of being silently absorbed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

if cluster_exists; then
  configure_kubeconfig

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

cd "$REPO_ROOT/terraform/live/${CLUSTER_DIR:-cluster}" && terragrunt run --all --non-interactive -- destroy -auto-approve

echo "CLUSTER-DOWN: destroy complete - checking for leaked disposable-lifecycle AWS resources..."
LEAK_COUNT=0

if [ "$PROVIDER" = "civo" ]; then
  civo_token

  LEAKED_CLUSTERS="$(civo_list_names kubernetes | grep -x -- "$PROJECT_NAME" || true)"
  if [ -n "$LEAKED_CLUSTERS" ]; then
    echo "CLUSTER-DOWN: leaked Civo cluster still present after destroy: $LEAKED_CLUSTERS" >&2
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # cluster/lb firewalls are Disposable-lifecycle (created alongside the
  # cluster under cluster-civo/network) - if terragrunt destroy above
  # succeeded these should already be gone. Genuine leak check, not
  # expected output on a healthy run.
  LEAKED_FIREWALLS="$(civo_list_names firewall | grep -x -e "${PROJECT_NAME}-k8s" -e "${PROJECT_NAME}-lb" || true)"
  if [ -n "$LEAKED_FIREWALLS" ]; then
    echo "CLUSTER-DOWN: leaked Civo firewall(s), deleting: $LEAKED_FIREWALLS" >&2
    for fw in $LEAKED_FIREWALLS; do
      civo_cli firewall remove "$fw" -y --region "$CIVO_REGION" >/dev/null 2>&1 || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # --dangling limits this to volumes whose owning cluster is already gone,
  # so a still-attached persistent volume on a live cluster is never touched.
  LEAKED_VOLUMES="$(civo_list_names volume --dangling | grep -- "^${PROJECT_NAME}" || true)"
  if [ -n "$LEAKED_VOLUMES" ]; then
    echo "CLUSTER-DOWN: leaked Civo dangling volume(s), deleting: $LEAKED_VOLUMES" >&2
    for vol in $LEAKED_VOLUMES; do
      civo_cli volume remove "$vol" -y --region "$CIVO_REGION" >/dev/null 2>&1 || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # civo CLI has no `loadbalancer remove` command (removed upstream - only
  # ls/show remain), so a leaked LB can only be reported here.
  LEAKED_LBS="$(civo_list_names loadbalancer | grep -- "^${PROJECT_NAME}" || true)"
  if [ -n "$LEAKED_LBS" ]; then
    echo "CLUSTER-DOWN: WARNING - leaked Civo load balancer(s), cannot delete via CLI (no 'civo loadbalancer remove' command exists): $LEAKED_LBS" >&2
    echo "CLUSTER-DOWN: delete manually via the Civo dashboard or API." >&2
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi
else
  LEAKED_INSTANCES="$(aws ec2 describe-instances --region "$LAB_REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_INSTANCES" ] && [ "$LEAKED_INSTANCES" != "None" ]; then
    echo "CLUSTER-DOWN: leaked instances, terminating: $LEAKED_INSTANCES" >&2
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --region "$LAB_REGION" --instance-ids $LEAKED_INSTANCES >/dev/null
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # No `status=available` filter here (unlike before) - an instance leaked
  # above may still hold its volume attached at the moment this runs, and a
  # status-scoped filter would silently skip exactly the volumes an orphaned
  # instance leaves behind.
  LEAKED_VOLUMES="$(aws ec2 describe-volumes --region "$LAB_REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Lifecycle,Values=disposable" \
    --query 'Volumes[?State!=`deleting`].VolumeId' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_VOLUMES" ] && [ "$LEAKED_VOLUMES" != "None" ]; then
    echo "CLUSTER-DOWN: leaked volumes, deleting: $LEAKED_VOLUMES" >&2
    for vol in $LEAKED_VOLUMES; do
      aws ec2 delete-volume --region "$LAB_REGION" --volume-id "$vol" 2>/dev/null || \
        echo "CLUSTER-DOWN:   $vol still attached (likely to the instance just terminated above) - will clear on its own once termination completes; re-run cluster-down to confirm." >&2
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # NLBs/target groups created by aws-load-balancer-controller aren't
  # Terraform-tracked, so the destroy above never touches them - tag-based
  # lookup is the only way to catch one stranded by the same cluster-already-
  # unreachable condition argo-down.sh warns about.
  LEAKED_NLBS="$(aws resourcegroupstaggingapi get-resources --region "$LAB_REGION" \
    --tag-filters "Key=Project,Values=$PROJECT_NAME" "Key=Lifecycle,Values=disposable" \
    --resource-type-filters elasticloadbalancing:loadbalancer elasticloadbalancing:targetgroup \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_NLBS" ] && [ "$LEAKED_NLBS" != "None" ]; then
    echo "CLUSTER-DOWN: leaked load balancers/target groups, deleting: $LEAKED_NLBS" >&2
    for arn in $LEAKED_NLBS; do
      case "$arn" in
        *:targetgroup/*) aws elbv2 delete-target-group --region "$LAB_REGION" --target-group-arn "$arn" 2>/dev/null || true ;;
        *:loadbalancer/*) aws elbv2 delete-load-balancer --region "$LAB_REGION" --load-balancer-arn "$arn" 2>/dev/null || true ;;
      esac
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # ENIs an NLB or the VPC CNI created for this cluster - never Terraform-
  # tracked, and outlive their NLB by a few minutes even in the healthy case,
  # so a failure to delete one here is expected on a fast re-run, not itself
  # a leak signal.
  LEAKED_ENIS="$(aws ec2 describe-network-interfaces --region "$LAB_REGION" \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_ENIS" ] && [ "$LEAKED_ENIS" != "None" ]; then
    echo "CLUSTER-DOWN: leaked ENIs, deleting: $LEAKED_ENIS" >&2
    for eni in $LEAKED_ENIS; do
      aws ec2 delete-network-interface --region "$LAB_REGION" --network-interface-id "$eni" 2>/dev/null || \
        echo "CLUSTER-DOWN:   $eni still attached - an NLB/security group above may need to finish deleting first." >&2
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # Security groups aws-load-balancer-controller creates for the NLB -
  # deleted only after the NLB/ENIs above, since AWS refuses to delete a
  # security group still referenced by either.
  LEAKED_SGS="$(aws ec2 describe-security-groups --region "$LAB_REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER_NAME" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_SGS" ] && [ "$LEAKED_SGS" != "None" ]; then
    echo "CLUSTER-DOWN: leaked security groups, deleting: $LEAKED_SGS" >&2
    for sg in $LEAKED_SGS; do
      aws ec2 delete-security-group --region "$LAB_REGION" --group-id "$sg" 2>/dev/null || \
        echo "CLUSTER-DOWN:   $sg still in use - re-run cluster-down once its ENI has cleared." >&2
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # Karpenter launch templates - Karpenter's own EC2NodeClass tags these
  # additively with the same Project tag as instances/volumes (confirmed in
  # nodepool.yaml), so the same tag filter that catches instances also finds
  # these.
  LEAKED_LTS="$(aws ec2 describe-launch-templates --region "$LAB_REGION" \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_LTS" ] && [ "$LEAKED_LTS" != "None" ]; then
    echo "CLUSTER-DOWN: leaked Karpenter launch templates, deleting: $LEAKED_LTS" >&2
    for lt in $LEAKED_LTS; do
      aws ec2 delete-launch-template --region "$LAB_REGION" --launch-template-id "$lt" 2>/dev/null || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # Karpenter's own EC2NodeClass finalizer normally removes its instance
  # profile; if the controller was torn down first (an earlier interrupted
  # `make down`), the profile is orphaned under this fixed path prefix with no
  # controller left to clean it up (see lab-role's
  # KarpenterOrphanedInstanceProfileCleanup statement).
  LEAKED_PROFILES="$(aws iam list-instance-profiles --path-prefix "/karpenter/$LAB_REGION/$CLUSTER_NAME/" \
    --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || true)"
  if [ -n "$LEAKED_PROFILES" ] && [ "$LEAKED_PROFILES" != "None" ]; then
    echo "CLUSTER-DOWN: leaked Karpenter instance profiles, deleting: $LEAKED_PROFILES" >&2
    for profile in $LEAKED_PROFILES; do
      role_name="$(aws iam get-instance-profile --instance-profile-name "$profile" \
        --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || true)"
      if [ -n "$role_name" ] && [ "$role_name" != "None" ]; then
        aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role_name" 2>/dev/null || true
      fi
      aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi
fi

# Deliberately not swept here: EBS snapshots (Project + Component=postgres
# tags only, no Lifecycle tag - the persistent recovery artifact ADR 0013
# depends on, cleaned up by persistent-down.sh at its own point in the
# lifecycle, never by cluster-down).
if [ "$LEAK_COUNT" -eq 0 ]; then
  echo "CLUSTER-DOWN: no leaked disposable-lifecycle resources found."
else
  echo "CLUSTER-DOWN: ERROR - $LEAK_COUNT category of leaked resource found and deletion attempted (see above)." >&2
  echo "CLUSTER-DOWN: the cascade in argo-down/cluster-down did not fully clean up on its own - this is a bug to fix," >&2
  echo "CLUSTER-DOWN: not a condition to silence (ADR 0012, ADR 0026). Failing so it surfaces." >&2
  exit 1
fi
