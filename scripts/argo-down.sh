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
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"
BACKUP_TIMEOUT="${ARGO_DOWN_BACKUP_TIMEOUT:-120s}"
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

# Absence is checked against the provider's own API, not kubectl - a 404
# there proves the cluster is gone, whereas a kubectl failure only proves
# this shell lacks a working kubeconfig, never proof of absence.
if ! cluster_exists; then
  echo "ARGO-DOWN: cluster $CLUSTER_NAME does not exist - nothing to cascade, skipping."
  exit 0
fi

configure_kubeconfig

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: ERROR - cluster $CLUSTER_NAME exists but is unreachable via kubectl (cluster-info failed)." >&2
  echo "ARGO-DOWN: refusing to proceed: without API access there is no way to ask Karpenter/aws-load-balancer-" >&2
  echo "ARGO-DOWN: controller to drain nodes and delete load balancers before the control plane is destroyed -" >&2
  echo "ARGO-DOWN: proceeding blind orphans them. Investigate cluster/API-server health before retrying." >&2
  exit 1
fi

# Disarming automated sync is the first thing done to a reachable cluster:
# everything below takes minutes, and a commit landing on the tracked
# branch inside that window starts a sync whose hooks then deadlock the
# cascade. Clearing spec.operation only drops a queued operation - one the
# controller already picked up is aborted by setting its status phase to
# Terminating, the same thing Argo's own terminate-op does.
DISARMED=0
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch application "$app" -n argocd --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  kubectl patch application "$app" -n argocd --type=merge -p '{"operation":null}' >/dev/null 2>&1
  if [ "$(kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = "Running" ]; then
    echo "ARGO-DOWN: aborting in-flight sync operation on application/$app..."
    kubectl patch application "$app" -n argocd --type=merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null 2>&1 || true
  fi
  DISARMED=$((DISARMED + 1))
done

# Every exit path below this point leaves GitOps disarmed, so say so - an
# operator who stops here on a backup failure would otherwise have no way
# to know the cluster's reconciliation is off.
if [ "$DISARMED" -gt 0 ]; then
  echo "ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'make argo-up' if you stop here."
fi

# Forces a cold VolumeSnapshot backup of Postgres before the cluster (and
# with it, the live EBS volume) gets torn down below - this is the only
# thing that survives a cluster-down/cluster-up cycle now that the
# volume itself is Delete-reclaim (ADR 0013). Must run and complete before
# the cascade delete starts: the Cluster/pod need to still be alive.
# Aborts loudly on failure rather than proceeding - proceeding would
# destroy the only copy.
aws_cnpg_backup_and_prune() {
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
  if ! OLD_SNAPSHOTS="$(aws ec2 describe-snapshots --region "$LAB_REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" \
    --query 'sort_by(Snapshots,&StartTime)[:-2].SnapshotId' --output text)"; then
    echo "ARGO-DOWN: failed to list Postgres EBS snapshots for pruning - aborting." >&2
    exit 1
  fi
  if [ -n "$OLD_SNAPSHOTS" ] && [ "$OLD_SNAPSHOTS" != "None" ]; then
    for snapshot_id in $OLD_SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$LAB_REGION" --snapshot-id "$snapshot_id"
      echo "ARGO-DOWN: pruned old snapshot $snapshot_id"
    done
  fi
else
  echo "ARGO-DOWN: no lab-postgres Cluster found - skipping pre-teardown backup."
fi
}

if [ "$PROVIDER" != civo ]; then
  aws_cnpg_backup_and_prune
fi

# Argo deletes one sync wave at a time and refuses to start the next while
# any object it manages still has a deletionTimestamp - so a single object
# whose finalizer never clears freezes the whole cascade silently. Report
# live objects stuck Terminating and the finalizer holding each one: the
# finalizer names the controller that owes the cleanup. Reading Argo's own
# .status.resources instead would lie here, since that is its tracked
# desired-state view and keeps listing resources already deleted.
TERMINATING_KINDS="application.argoproj.io cluster.postgresql.cnpg.io \
nodepool.karpenter.sh ec2nodeclass.karpenter.k8s.aws nodeclaim.karpenter.sh \
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
  # Argo never processes a deletion finalizer while a sync operation is in
  # flight, so a root still Running here means deadlocked, not draining -
  # the one fact that distinguishes the two, printed instead of dug for.
  local op
  op="$(kubectl get application root -n argocd \
    -o jsonpath='{.status.operationState.phase} - {.status.operationState.message}' 2>/dev/null || true)"
  if [ -n "${op% - *}" ]; then
    echo "ARGO-DOWN: root sync operation: $op"
  fi
}

echo "ARGO-DOWN: deleting HTTPRoutes to trigger ExternalDNS record cleanup..."
kubectl delete httproute -A --all >/dev/null 2>&1 || true

# external-dns is not guaranteed to survive the Karpenter node drain below
# (it is now pinned to node-type: system, but confirm rather than assume -
# constitution S7: a controller must stay alive until what it manages is
# actually cleaned up). Poll Route 53 directly for its own TXT ownership
# records under the lab zone until none remain, instead of trusting timing.
SUBDOMAIN="${SUBDOMAIN:-lab}"
ROOT_DOMAIN="$("$REPO_ROOT/scripts/secret-decrypt.sh" root-domain)"
FQDN="${SUBDOMAIN}.${ROOT_DOMAIN}"
ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$FQDN" --region "$LAB_REGION" \
  --query "HostedZones[?Name=='${FQDN}.'].Id" --output text 2>/dev/null || true)"
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "ARGO-DOWN: WARNING - could not resolve hosted zone for $FQDN, skipping wait." >&2
  else
    DNS_WAIT_TIMEOUT="${ARGO_DOWN_DNS_TIMEOUT:-180}"
    dns_elapsed=0
    while true; do
      # heritage=external-dns is the TXT registry's own marker (registry:
      # txt in the Helm values) - matches only records it created, never
      # NS/SOA or ACM's unrelated _acme-challenge validation TXT.
      remaining_count="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
        --query 'ResourceRecordSets[].ResourceRecords[].Value' --output json 2>/dev/null \
        | jq '[.[] | select(contains("heritage=external-dns"))] | length')"
      remaining_count="${remaining_count:-0}"
      if [ "$remaining_count" -eq 0 ]; then
        echo "ARGO-DOWN: ExternalDNS-owned Route 53 records confirmed gone."
        break
      fi
      if [ "$dns_elapsed" -ge "$DNS_WAIT_TIMEOUT" ]; then
        echo "ARGO-DOWN: $remaining_count ExternalDNS-owned record(s) still present in $FQDN after ${DNS_WAIT_TIMEOUT}s - refusing to proceed." >&2
        echo "ARGO-DOWN: check 'aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID' before retrying." >&2
        exit 1
      fi
      echo "ARGO-DOWN: waiting on $remaining_count ExternalDNS-owned Route 53 record(s) to clear... (${dns_elapsed}s/${DNS_WAIT_TIMEOUT}s)"
      sleep "$POLL_INTERVAL"
      dns_elapsed=$((dns_elapsed + POLL_INTERVAL))
    done
  fi

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

# Argo stamps a deletionTimestamp on a hook Job it is done with, but can
# leave its own hook-finalizer behind. The unreaped Job then holds the sync
# operation Running forever, and no finalizer - including root's - is ever
# processed while an operation is in flight: a closed deadlock the cascade
# below cannot break out of, only time out on.
kubectl get jobs -A -o json 2>/dev/null \
  | jq -r '.items[]? | select((.metadata.finalizers // []) | index("argocd.argoproj.io/hook-finalizer"))
      | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r hook_ns hook_name; do
      [ -n "$hook_name" ] || continue
      echo "ARGO-DOWN: releasing orphaned Argo hook finalizer on job/$hook_name (namespace $hook_ns)..."
      kubectl patch job "$hook_name" -n "$hook_ns" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done

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
