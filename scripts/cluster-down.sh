#!/usr/bin/env bash
# Implements `make cluster-down`: destroys Disposable-lifecycle resources.
# Refuses to run if Argo CD's
# root Application still exists on a reachable cluster - that means
# `make argo-down` hasn't completed, and proceeding anyway is what causes
# Karpenter's orphaned EC2 instances to block the node security group's
# destroy with DependencyViolation (ADR 0012, spec 006-1). Proceeds
# unconditionally if the cluster is unreachable - there's nothing to check
# against, and a prior interrupted destroy must stay resumable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  if kubectl get application root -n argocd >/dev/null 2>&1; then
    echo "Argo CD's root Application still exists - run 'make argo-down' first." >&2
    exit 1
  fi
fi

cd "$REPO_ROOT/terraform/live/disposable" && terragrunt run --all destroy --non-interactive -auto-approve
