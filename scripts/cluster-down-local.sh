#!/usr/bin/env bash
# Deletes the disposable kind cluster and everything in it. No CONFIRM_DESTROY
# guard: kind deletes only kind clusters, and local data is throwaway by design.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"

if [ "$PROVIDER" != "local" ]; then
  echo "cluster-down-local.sh: PROVIDER must be local, got '$PROVIDER'" >&2
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "cluster-down-local.sh: kind is not installed - see https://kind.sigs.k8s.io" >&2
  exit 1
fi

if ! cluster_exists; then
  echo "kind cluster $CLUSTER_NAME does not exist - nothing to delete."
  exit 0
fi

kind delete cluster --name "$CLUSTER_NAME"
