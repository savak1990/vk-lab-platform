#!/usr/bin/env bash
# Creates the disposable kind cluster. Reaches no cloud API and needs no
# credentials - the whole local target is one kind node on this machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"

if [ "$PROVIDER" != "local" ]; then
  echo "cluster-up-local.sh: PROVIDER must be local, got '$PROVIDER'" >&2
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "cluster-up-local.sh: kind is not installed - see https://kind.sigs.k8s.io" >&2
  exit 1
fi

use_isolated_kubeconfig

if cluster_exists; then
  echo "kind cluster $CLUSTER_NAME already exists."
else
  # Unpinned by default: the installed kind version picks a node image it was
  # built and tested against. CI pins kind itself, which pins this too.
  image_args=()
  [ -n "${KIND_NODE_IMAGE:-}" ] && image_args=(--image "$KIND_NODE_IMAGE")
  kind create cluster --name "$CLUSTER_NAME" ${image_args[@]:+"${image_args[@]}"}
fi

configure_kubeconfig "$KUBECONFIG"
require_local_context
kubectl cluster-info
