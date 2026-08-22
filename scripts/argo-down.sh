#!/usr/bin/env bash
# Cascades away everything Argo CD owns, then removes Argo CD itself -
# before disposable-down touches the EKS cluster. The cascade is what lets
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

TIMEOUT="${ARGO_DOWN_TIMEOUT:-300s}"
POLL_INTERVAL="${ARGO_DOWN_POLL_INTERVAL:-5}"
REGION="${REGION:-eu-west-1}"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BACKUP_TIMEOUT="${ARGO_DOWN_BACKUP_TIMEOUT:-120s}"
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: cluster unreachable - nothing to cascade, skipping."
  exit 0
fi

# Forces a cold VolumeSnapshot backup of Postgres before the cluster (and
# with it, the live EBS volume) gets torn down below - this is the only
# thing that survives a disposable-down/disposable-up cycle now that the
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

# Argo updates status.resources wave by wave as it prunes, so polling it
# while the blocking delete below runs shows which components are still
# going away - not just that we're waiting.
report_remaining() {
  local remaining
  remaining="$(kubectl get application root -n argocd \
    -o jsonpath='{range .status.resources[?(@.status!="")]}{.kind}/{.name}={.status} {end}' 2>/dev/null || true)"
  echo "ARGO-DOWN: still waiting on: ${remaining:-root Application finalizer}"
}

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
