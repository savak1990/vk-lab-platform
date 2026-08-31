#!/usr/bin/env bash
# Cascades away everything Argo CD owns, then removes Argo CD itself -
# before cluster-down touches the EKS cluster. The cascade is what lets
# Karpenter's controller drain and terminate its own nodes before it
# disappears (ADR 0012, spec 006-1); it relies on the
# resources-finalizer.argocd.argoproj.io finalizer on the root Application
# (and its children) plus Argo's wave-reversed prune order - one generic
# mechanism, not a drain script per component.
#
# The cascade itself goes through `kubectl delete`, not `helm uninstall`:
# Helm's own uninstall --wait can't be trusted to block through a
# finalizer-gated cascade (the same terraform-provider-helm limitation
# ADR 0012 found applies to plain `helm uninstall` too, same underlying
# Helm SDK). Once the cascade is confirmed done, `helm uninstall` is used
# to actually remove Argo CD and keep Helm's release records honest.
set -euo pipefail

TIMEOUT="${ARGO_DOWN_TIMEOUT:-900s}"
POLL_INTERVAL="${ARGO_DOWN_POLL_INTERVAL:-5}"
REGION="${REGION:-eu-west-1}"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BACKUP_TIMEOUT="${ARGO_DOWN_BACKUP_TIMEOUT:-120s}"
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: cluster unreachable - nothing to cascade, skipping."
  # The cascade below is the only thing that lets Karpenter drain and
  # terminate its own nodes gracefully - if the cluster is already gone
  # (e.g. a prior make down attempt got through cluster-down but failed
  # later), any Karpenter-owned instance still running here was never
  # drained and never will be. Surfacing it now, not just when it later
  # blocks a security-group destroy with DependencyViolation.
  STRAY="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:eks-cluster-name,Values=${PROJECT_NAME}-eks" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [ -n "$STRAY" ] && [ "$STRAY" != "None" ]; then
    echo "ARGO-DOWN: WARNING - found instance(s) tagged for this cluster that can no longer be gracefully drained (cluster already unreachable): $STRAY" >&2
    echo "ARGO-DOWN: these will likely block cluster-down's security-group destroy - terminate manually if so." >&2
  fi
  # Same reasoning as above, but for the NLB: the Gateway-deletion-and-wait
  # block further down is the only thing that gets aws-load-balancer-
  # controller to actually delete the NLB (and external-dns to clean up its
  # DNS records) before those controllers disappear with the cluster. If we
  # never reached that block, both are now stuck the same way.
  # aws-load-balancer-controller-created NLBs get a hashed name, not one
  # containing PROJECT_NAME - tag-based lookup is the only reliable match.
  STRAY_NLBS="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=Project,Values=$PROJECT_NAME" "Key=Lifecycle,Values=disposable" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)"
  if [ -n "$STRAY_NLBS" ] && [ "$STRAY_NLBS" != "None" ]; then
    echo "ARGO-DOWN: WARNING - found NLB(s) that can no longer be gracefully deleted (cluster already unreachable): $STRAY_NLBS" >&2
    echo "ARGO-DOWN: aws-load-balancer-controller and external-dns are both gone - delete the NLB, its security groups, and any lab.<root-domain> DNS records pointing at it manually." >&2
  fi
  exit 0
fi

# Forces a cold VolumeSnapshot backup of Postgres before the cluster (and
# with it, the live EBS volume) gets torn down below - this is the only
# thing that survives a cluster-down/cluster-up cycle now that the
# volume itself is Delete-reclaim (ADR 0013). Must run and complete before
# the cascade delete starts: the Cluster/pod need to still be alive.
# Aborts loudly on failure rather than proceeding - proceeding would
# destroy the only copy.
if kubectl get cluster lab-postgres -n cnpg-system >/dev/null 2>&1; then
  BACKUP_NAME="lab-postgres-teardown-$(date +%s 2>/dev/null || echo manual)"
  echo "ARGO-DOWN: forcing a pre-teardown Postgres volume-snapshot backup ($BACKUP_NAME)..."
  cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP_NAME
  namespace: cnpg-system
spec:
  cluster:
    name: lab-postgres
  method: volumeSnapshot
EOF

  # No streamed byte-progress exists for a cold volumeSnapshot backup, but
  # CNPG does report discrete phases - poll and print those every
  # POLL_INTERVAL rather than blocking silently for the full timeout.
  backup_elapsed=0
  backup_timeout_secs="${BACKUP_TIMEOUT%s}"
  while true; do
    phase="$(kubectl get backup "$BACKUP_NAME" -n cnpg-system -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "ARGO-DOWN: backup phase: ${phase:-pending} (${backup_elapsed}s/${BACKUP_TIMEOUT})"
    if [ "$phase" = "completed" ]; then
      echo "ARGO-DOWN: pre-teardown backup completed."
      break
    elif [ "$phase" = "failed" ]; then
      echo "ARGO-DOWN: pre-teardown backup reported phase 'failed' - refusing to proceed." >&2
      echo "ARGO-DOWN: check 'kubectl describe backup $BACKUP_NAME -n cnpg-system'." >&2
      exit 1
    elif [ "$backup_elapsed" -ge "$backup_timeout_secs" ]; then
      echo "ARGO-DOWN: pre-teardown backup did not complete within $BACKUP_TIMEOUT - refusing to proceed." >&2
      echo "ARGO-DOWN: check 'kubectl describe backup $BACKUP_NAME -n cnpg-system' before retrying." >&2
      exit 1
    fi
    sleep "$POLL_INTERVAL"
    backup_elapsed=$((backup_elapsed + POLL_INTERVAL))
  done

  # No status=completed filter here (unlike argo-up.sh's discovery query):
  # the AWS-side snapshot is still asynchronously "pending" for a while
  # after CNPG reports the Backup done, so filtering to completed-only at
  # prune time would miscount "newest 2" and delete the wrong one. Count
  # everything tagged, regardless of state.
  echo "ARGO-DOWN: pruning old Postgres EBS snapshots (keeping newest 2)..."
  if ! OLD_SNAPSHOTS="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" \
    --query 'sort_by(Snapshots,&StartTime)[:-2].SnapshotId' --output text)"; then
    echo "ARGO-DOWN: failed to list Postgres EBS snapshots for pruning - aborting." >&2
    exit 1
  fi
  if [ -n "$OLD_SNAPSHOTS" ] && [ "$OLD_SNAPSHOTS" != "None" ]; then
    for snapshot_id in $OLD_SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snapshot_id"
      echo "ARGO-DOWN: pruned old snapshot $snapshot_id"
    done
  fi
else
  echo "ARGO-DOWN: no lab-postgres Cluster found - skipping pre-teardown backup."
fi

# Argo deletes one sync wave at a time and refuses to start the next while
# any object it manages still has a deletionTimestamp - so a single object
# whose finalizer never clears freezes the whole cascade silently. Report
# live objects stuck Terminating and the finalizer holding each one: the
# finalizer names the controller that owes the cleanup. Reading Argo's own
# .status.resources instead would lie here, since that is its tracked
# desired-state view and keeps listing resources already deleted.
TERMINATING_KINDS="application.argoproj.io cluster.postgresql.cnpg.io \
nodepool.karpenter.sh ec2nodeclass.karpenter.k8s.aws \
volumesnapshot.snapshot.storage.k8s.io volumesnapshotcontent.snapshot.storage.k8s.io \
volumesnapshotclass.snapshot.storage.k8s.io storageclass.storage.k8s.io \
clustersecretstore.external-secrets.io externalsecret.external-secrets.io \
volumeattachment.storage.k8s.io persistentvolume"

report_remaining() {
  local stuck=""
  for kind in $TERMINATING_KINDS; do
    stuck+="$(kubectl get "$kind" -A --ignore-not-found -o json 2>/dev/null \
      | jq -r --arg k "${kind%%.*}" '.items[]? | select(.metadata.deletionTimestamp)
          | "\($k)/\(.metadata.name)[\(.metadata.finalizers // ["none"] | join(","))]"' 2>/dev/null || true) "
  done
  stuck="$(echo "$stuck" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
  if [ -n "$stuck" ]; then
    echo "ARGO-DOWN: still terminating: $stuck"
  else
    echo "ARGO-DOWN: nothing stuck terminating - waiting on root's own finalizer."
  fi
  # Which child Application(s) - cnpg-operator, karpenter, ... - are still
  # around, so a single one stuck deleting is visible by name instead of
  # only root's own aggregate status.
  local remaining
  remaining="$(kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '[.items[].metadata.name] | join(", ")')"
  echo "ARGO-DOWN: applications remaining: ${remaining:-none}"
}

# A child stuck retrying a doomed sync (selfHeal) never finishes an
# operation, and Argo won't prune a child mid-operation - wedging the
# cascade below. Disarming automated sync stops new ones; clearing any
# in-flight operation (e.g. waiting on a DaemonSet health check that will
# never pass once nodes start draining) aborts the one already stuck.
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch application "$app" -n argocd --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  kubectl patch application "$app" -n argocd --type=merge -p '{"operation":null}' >/dev/null 2>&1
done

# Deleted early, not waited-on: external-dns is still running and has the
# whole remaining cascade to reconcile the Route 53 records away. Add a
# wait here only if a real `make down` ever leaves records behind.
echo "ARGO-DOWN: deleting HTTPRoutes to trigger ExternalDNS record cleanup..."
kubectl delete httproute -A --all >/dev/null 2>&1 || true

# The Service behind the NLB is a controller side effect, not an
# Argo-applied resource - the cascade below doesn't wait on it before
# killing the controller that deletes it. Trigger and wait here instead.
nlb_svc_before="$(kubectl get svc -n envoy -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {end}' 2>/dev/null || true)"
if [ -n "$nlb_svc_before" ]; then
  echo "ARGO-DOWN: deleting Gateway to trigger NLB teardown (Service: $nlb_svc_before)..."
  kubectl delete gateway platform-gateway -n envoy --ignore-not-found >/dev/null 2>&1 || true

  NLB_WAIT_TIMEOUT="${ARGO_DOWN_NLB_TIMEOUT:-300}"
  nlb_elapsed=0
  while true; do
    remaining_svc="$(kubectl get svc -n envoy -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name} {end}' 2>/dev/null || true)"
    if [ -z "$remaining_svc" ]; then
      echo "ARGO-DOWN: Envoy-managed NLB Service confirmed gone."
      break
    fi
    if [ "$nlb_elapsed" -ge "$NLB_WAIT_TIMEOUT" ]; then
      echo "ARGO-DOWN: Envoy-managed NLB Service ($remaining_svc) still present after ${NLB_WAIT_TIMEOUT}s - refusing to proceed." >&2
      echo "ARGO-DOWN: the real AWS NLB is likely still being torn down by aws-load-balancer-controller; check 'kubectl get svc -n envoy -o yaml' before retrying." >&2
      exit 1
    fi
    echo "ARGO-DOWN: waiting on Envoy-managed NLB Service ($remaining_svc) to finish deleting... (${nlb_elapsed}s/${NLB_WAIT_TIMEOUT}s)"
    sleep "$POLL_INTERVAL"
    nlb_elapsed=$((nlb_elapsed + POLL_INTERVAL))
  done
else
  echo "ARGO-DOWN: no NLB Service present in envoy namespace - nothing to wait on."
fi

if kubectl get application root -n argocd >/dev/null 2>&1; then
  echo "ARGO-DOWN: deleting root Application (cascade=foreground, waits for Karpenter/CNPG/etc. to fully drain)..."
  kubectl delete application root -n argocd --cascade=foreground --wait --timeout="$TIMEOUT" &
  DELETE_PID=$!

  while kill -0 "$DELETE_PID" 2>/dev/null; do
    sleep "$POLL_INTERVAL"
    kill -0 "$DELETE_PID" 2>/dev/null && report_remaining
  done

  wait "$DELETE_PID"
  echo "ARGO-DOWN: cascade complete."
else
  echo "ARGO-DOWN: root Application already gone - skipping cascade."
fi

# Final step: remove Argo CD itself. By now everything it managed is
# already gone, so this just tears down Argo CD's own Deployments/RBAC -
# no finalizers to wait through.
for release in root-application argocd; do
  if helm status "$release" -n argocd >/dev/null 2>&1; then
    echo "ARGO-DOWN: uninstalling Helm release '$release'..."
    helm uninstall "$release" -n argocd --wait
  fi
done

echo "ARGO-DOWN: Argo CD removed."
