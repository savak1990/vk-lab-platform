#!/usr/bin/env bash
# Implements `make park` and `make unpark`: takes the worker nodes to zero and
# brings them back, leaving the control plane, etcd, every Argo CD object, the
# volumes, the load balancer and its DNS records alone. A parked cluster answers
# kubectl and schedules nothing.
#
# Not a teardown and not a bring-up: it creates and destroys nothing outside the
# Disposable class that `make up` and `make down` already own. Argo CD's root
# Application is required to exist and is never deleted - it is what makes
# cluster-down refuse, and a parked cluster's servers and volumes still carry
# the labels a teardown sweep matches on.
#
# Hetzner only. The other targets refuse and say why.
# Usage: scripts/park.sh park | scripts/park.sh unpark
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

DIRECTION="${1:-}"
case "$DIRECTION" in
  park|unpark) ;;
  *) echo "PARK: usage: scripts/park.sh park|unpark" >&2; exit 2 ;;
esac

# A fixed prefix rather than the direction upper-cased: ${x^^} needs bash 4
# and macOS ships 3.2.
log() { echo "PARK: $*"; }
die() { echo "PARK: $*" >&2; exit 1; }

case "$PROVIDER" in
  hetzner) ;;
  aws)
    die "not supported on aws. The EKS control plane bills whether or not a node exists, so parking saves about a fifth of the bill; the node group's min, max and desired size are one variable that the next apply restores; and Karpenter, which creates every other node, runs on the very node group park would remove. Tear the cluster down with 'make down' instead."
    ;;
  civo)
    die "not supported on civo. The in-cluster autoscaler owns the pool count and would restore it, and a pool count of zero is untested against the Civo API. Tear the cluster down with 'make down' instead."
    ;;
  local)
    die "not supported on local: a kind cluster owns no cloud resources and costs nothing to leave running."
    ;;
  *)
    die "unknown PROVIDER '$PROVIDER'."
    ;;
esac

# Keeps kubectl on a repo-local kubeconfig: this must never change the context
# the operator is working in.
use_isolated_kubeconfig

hcloud_token

cluster_exists || die "cluster $CLUSTER_NAME does not exist. Use 'make up' to create it."
configure_kubeconfig "$KUBECONFIG"
api_reachable || die "cluster $CLUSTER_NAME is unreachable via kubectl. A park needs a live API server to drain through, and an unpark needs one to rejoin."

# Root absent means a teardown is in progress or never finished. Parking on top
# of that would leave a half-destroyed cluster wearing a parked cluster's shape.
kubectl get application root -n argocd >/dev/null 2>&1 \
  || die "Argo CD's root Application does not exist, so this cluster is not fully up. Run 'make up' first."

# The cloud's answer, not Kubernetes': a Node object can outlive its server.
fixed_workers="$(hcloud_list_names server role=worker 2>/dev/null || true)"
autoscaled="$(hcloud_list_names server managed_by=autoscaler 2>/dev/null || true)"
worker_servers="$(printf '%s\n%s\n' "$fixed_workers" "$autoscaled" | grep -c . || true)"

terragrunt_apply() {
  log "applying the cluster stack with MIN_WORKER_NODES=$MIN_WORKER_NODES"
  cd "$REPO_ROOT/terraform/live/$CLUSTER_DIR"
  terragrunt run --all --non-interactive -- apply -auto-approve
  cd "$REPO_ROOT"
}

if [ "$DIRECTION" = park ]; then
  if [ "$worker_servers" -eq 0 ]; then
    log "already parked - no worker server in project $PROJECT_NAME. Nothing to do."
    exit 0
  fi

  # Drained before the servers go, so CNPG stops cleanly and the CSI driver
  # detaches the volume rather than leaving it attached to a deleted server.
  for node in $(kubectl get nodes \
    -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    log "draining $node"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
      --timeout="${PARK_DRAIN_SECONDS:-300}s" || log "drain of $node did not complete cleanly - continuing"
  done

  MIN_WORKER_NODES=0
  export MIN_WORKER_NODES
  terragrunt_apply

  # Autoscaled servers are not in Terraform's state, so the apply above does not
  # touch them. Left alone they would keep billing beside a parked cluster.
  for srv in $autoscaled; do
    log "deleting autoscaled server $srv"
    hcloud_cli server delete "$srv" >/dev/null 2>&1 || log "could not delete $srv - check the Hetzner console"
  done

  # Nothing else in this repo reaps a Node object. A stale NotReady one would
  # make the unpark's readiness wait fail for as long as its budget lasts.
  for node in $(kubectl get nodes \
    -l '!node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    log "deleting stale Node object $node"
    kubectl delete node "$node" --ignore-not-found >/dev/null 2>&1 || true
  done

  log "parked. The control plane, etcd, the volumes, the load balancer and its DNS records are untouched."
  log "Every platform workload is now Pending, Postgres included. Run 'make unpark' to bring the workers back."
else
  if [ "$worker_servers" -gt 0 ]; then
    die "not parked - project $PROJECT_NAME already has $worker_servers worker server(s). Nothing to do."
  fi

  terragrunt_apply
  wait_for_nodes_ready
  log "unparked with $MIN_WORKER_NODES worker(s). Argo CD reschedules the platform from here; watch it with 'make status'."
fi
