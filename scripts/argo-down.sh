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
STUCK_APP_DWELL="${ARGO_DOWN_STUCK_APP_DWELL:-180}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"

# Keeps kubectl and helm on a repo-local kubeconfig: a lifecycle run must never
# change the context the operator is working in.
use_isolated_kubeconfig
PVC_WAIT_TIMEOUT="${ARGO_DOWN_PVC_WAIT_TIMEOUT:-180s}"

# Absence is checked against the provider's own API, not kubectl - a 404
# there proves the cluster is gone, whereas a kubectl failure only proves
# this shell lacks a working kubeconfig, never proof of absence.
if ! cluster_exists; then
  echo "ARGO-DOWN: cluster $CLUSTER_NAME does not exist - nothing to cascade, skipping."
  exit 0
fi

configure_kubeconfig "$KUBECONFIG"

if ! api_reachable; then
  echo "ARGO-DOWN: ERROR - cluster $CLUSTER_NAME exists but is unreachable via kubectl (cluster-info failed)." >&2
  echo "ARGO-DOWN: refusing to proceed: without API access there is no way to ask Karpenter/aws-load-balancer-" >&2
  echo "ARGO-DOWN: controller to drain nodes and delete load balancers before the control plane is destroyed -" >&2
  echo "ARGO-DOWN: proceeding blind orphans them. Investigate cluster/API-server health before retrying." >&2
  exit 1
fi

if [ "$PROVIDER" = civo ]; then
  civo_export_tls_secret
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
  DISARMED=$((DISARMED + 1))
done

# Before terminating anything: release hook objects Argo has stamped for
# deletion but still holds its own finalizer on. Terminating first is what
# fails - once the controller is already waiting on a hook, reaping that hook
# afterwards does not make it re-evaluate, so the operation waits forever for
# an object that no longer exists. Sweep pods as well as jobs; the finalizer
# is not specific to Jobs.
release_orphaned_hooks() {
  local hook_kind
  # One kind per query: an item's own .kind is only populated on multi-resource
  # gets, and a wrong kind here would patch nothing while reporting success.
  for hook_kind in job pod; do
    kubectl get "$hook_kind" -A -o json 2>/dev/null \
      | jq -r '.items[]? | select((.metadata.finalizers // []) | index("argocd.argoproj.io/hook-finalizer"))
          | "\(.metadata.namespace) \(.metadata.name)"' \
      | while read -r hook_ns hook_name; do
          [ -n "$hook_name" ] || continue
          echo "ARGO-DOWN: releasing orphaned Argo hook finalizer on ${hook_kind}/$hook_name (namespace $hook_ns)..."
          kubectl patch "$hook_kind" "$hook_name" -n "$hook_ns" --type=merge \
            -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        done || true
  done
}
release_orphaned_hooks

# Now wind operations down. Setting the phase to Terminating is what Argo's own
# terminate-op does, but it only asks the controller to finish - a controller
# blocked on a vanished hook never does. So after a dwell, drop the stale
# operation state outright: no finalizer, root's included, is ever processed
# while an operation is in flight, and that is what deadlocks the cascade.
for app in $(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  if [ "$(kubectl get application "$app" -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null)" = "Running" ]; then
    echo "ARGO-DOWN: aborting in-flight sync operation on application/$app..."
    kubectl patch application "$app" -n argocd --type=merge \
      -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null 2>&1 || true
  fi
done

OP_CLEAR_DWELL="${ARGO_DOWN_OP_CLEAR_DWELL:-60}"
op_elapsed=0
while [ "$op_elapsed" -lt "$OP_CLEAR_DWELL" ]; do
  stuck_ops="$(kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '.items[]? | select((.status.operationState.phase // "") | test("Running|Terminating"))
        | .metadata.name' 2>/dev/null || true)"
  [ -z "$stuck_ops" ] && break
  sleep "$POLL_INTERVAL"
  op_elapsed=$((op_elapsed + POLL_INTERVAL))
done
for app in ${stuck_ops:-}; do
  echo "ARGO-DOWN: operation on application/$app did not wind down in ${OP_CLEAR_DWELL}s - dropping its stale operation state."
  kubectl patch application "$app" -n argocd --type=json \
    -p '[{"op":"remove","path":"/status/operationState"}]' >/dev/null 2>&1 || true
done

# Every exit path below this point leaves GitOps disarmed, so say so - an
# operator who stops here on a cascade or DNS failure would otherwise have no way
# to know the cluster's reconciliation is off.
if [ "$DISARMED" -gt 0 ]; then
  if [ "$PROVIDER" = civo ]; then
    echo "ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'PROVIDER=civo make argo-up' if you stop here."
  else
    echo "ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'make argo-up' if you stop here."
  fi
fi

# Best effort: WAL archiving already made every committed row durable, so a
# failed final base backup never blocks the teardown.
backup_teardown

# Argo deletes one sync wave at a time and refuses to start the next while
# any object it manages still has a deletionTimestamp - so a single object
# whose finalizer never clears freezes the whole cascade silently. Report
# live objects stuck Terminating and the finalizer holding each one: the
# finalizer names the controller that owes the cleanup. Reading Argo's own
# .status.resources instead would lie here, since that is its tracked
# desired-state view and keeps listing resources already deleted.
TERMINATING_KINDS="application.argoproj.io cluster.postgresql.cnpg.io \
nodepool.karpenter.sh ec2nodeclass.karpenter.k8s.aws nodeclaim.karpenter.sh \
storageclass.storage.k8s.io \
clustersecretstore.external-secrets.io externalsecret.external-secrets.io \
volumeattachment.storage.k8s.io persistentvolume"

if [ "$PROVIDER" = civo ]; then
  filtered_kinds=""
  for kind in $TERMINATING_KINDS; do
    kubectl get "$kind" -A >/dev/null 2>&1 && filtered_kinds="$filtered_kinds $kind"
  done
  TERMINATING_KINDS="$filtered_kinds"
fi

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
ROOT_DOMAIN="$(SECRET_SCOPE=global "$REPO_ROOT/scripts/secret-decrypt.sh" root-domain)"
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

# Swept once more immediately before the cascade: the waits above take
# minutes, and a hook left holding this finalizer blocks every deletion
# finalizer the cascade depends on, root's included.
release_orphaned_hooks

# Recorded before the cascade starts: once the PVC is gone the CSI driver
# still needs time to delete the backing Civo volume, and the PV itself is
# the only object left to poll for that during the wait below.
PRE_CASCADE_PVS=""
if [ "$PROVIDER" = civo ]; then
  PRE_CASCADE_PVS="$(kubectl get pv -o json 2>/dev/null \
    | jq -r '.items[]? | select((.spec.claimRef // {}).namespace == "cnpg-system" or (.spec.claimRef // {}).namespace == "observability") | .metadata.name' 2>/dev/null || true)"
fi

if kubectl get application root -n argocd >/dev/null 2>&1; then
  echo "ARGO-DOWN: deleting root Application (cascade=foreground, waits for Karpenter/CNPG/etc. to fully drain)..."
  kubectl delete application root -n argocd --cascade=foreground --wait --timeout="$TIMEOUT" &
  DELETE_PID=$!

  cascade_elapsed=0
  while kill -0 "$DELETE_PID" 2>/dev/null; do
    sleep "$POLL_INTERVAL"
    cascade_elapsed=$((cascade_elapsed + POLL_INTERVAL))
    kill -0 "$DELETE_PID" 2>/dev/null && report_remaining
    # Last resort, and deliberately narrow. An Application that has been
    # marked for deletion this long, still carries only Argo's own
    # resources-finalizer, and has nothing left in status.resources has no
    # cleanup left to do - the finalizer is just stuck. Releasing it lets the
    # cascade past. The empty-resources check is the safety: never drop this
    # finalizer while Argo still believes it owns live objects.
    if [ "$cascade_elapsed" -ge "$STUCK_APP_DWELL" ]; then
      kubectl get applications -n argocd -o json 2>/dev/null \
        | jq -r '.items[]? | select(.metadata.deletionTimestamp)
            | select((.metadata.finalizers // []) == ["resources-finalizer.argocd.argoproj.io"])
            | select(((.status.resources // []) | length) == 0)
            | .metadata.name' 2>/dev/null \
        | while read -r stuck_app; do
            [ -n "$stuck_app" ] || continue
            echo "ARGO-DOWN: application/$stuck_app deleting for ${cascade_elapsed}s with no resources left - releasing its finalizer."
            kubectl patch application "$stuck_app" -n argocd --type=merge \
              -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
          done
    fi
  done

  wait "$DELETE_PID"
  echo "ARGO-DOWN: cascade complete."
else
  echo "ARGO-DOWN: root Application already gone - skipping cascade."
fi

# The PVC/PV teardown is async relative to the Cluster object going away,
# and a Civo volume that outlives the cluster keeps billing - cluster-down
# treats one as a cascade bug and fails, so confirm it here instead.
if [ "$PROVIDER" = civo ]; then
  for pvc_ns in cnpg-system observability; do
    if [ -n "$(kubectl get pvc -n "$pvc_ns" -o name 2>/dev/null)" ]; then
      echo "ARGO-DOWN: waiting for $pvc_ns PVCs to finish deleting..."
      if ! kubectl wait --for=delete pvc -n "$pvc_ns" --all --timeout="$PVC_WAIT_TIMEOUT"; then
        echo "ARGO-DOWN: WARNING - $pvc_ns PVCs still present after ${PVC_WAIT_TIMEOUT}; the Civo volume may" >&2
        echo "ARGO-DOWN: outlive the cluster. cluster-down's dangling-volume sweep will catch and delete it, and" >&2
        echo "ARGO-DOWN: will fail the run so this surfaces rather than being absorbed." >&2
      fi
    else
      echo "ARGO-DOWN: no $pvc_ns PVCs present - nothing to wait on."
    fi
  done

  # The PVC is only the Kubernetes-side handle; the CSI driver deletes the
  # backing Civo volume afterward. Wait on each recorded PV directly so a
  # slow delete surfaces here instead of as a false leak in cluster-down.
  for pv in $PRE_CASCADE_PVS; do
    if kubectl get pv "$pv" >/dev/null 2>&1; then
      echo "ARGO-DOWN: waiting for PV $pv (civo volume) to finish deleting..."
      if ! kubectl wait --for=delete "pv/$pv" --timeout="$PVC_WAIT_TIMEOUT"; then
        echo "ARGO-DOWN: WARNING - PV $pv still present after ${PVC_WAIT_TIMEOUT}; the Civo volume may" >&2
        echo "ARGO-DOWN: outlive the cluster. cluster-down's dangling-volume sweep will catch and delete it, and" >&2
        echo "ARGO-DOWN: will fail the run so this surfaces rather than being absorbed." >&2
      fi
    fi
  done
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
