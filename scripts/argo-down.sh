#!/usr/bin/env bash
# Cascades away everything Argo CD owns before disposable-down touches the
# EKS cluster - this is what lets Karpenter's controller drain and
# terminate its own nodes before it disappears (ADR 0012, spec 006-1).
# Relies on the resources-finalizer.argocd.argoproj.io finalizer on the
# root Application (and its children) plus Argo's wave-reversed prune
# order - one generic mechanism, not a drain script per component.
set -euo pipefail

TIMEOUT="${ARGO_DOWN_TIMEOUT:-300s}"

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: cluster unreachable - nothing to cascade, skipping."
  exit 0
fi

if ! kubectl get application root -n argocd >/dev/null 2>&1; then
  echo "ARGO-DOWN: root Application already gone - nothing to do."
  exit 0
fi

echo "ARGO-DOWN: deleting root Application (cascade=foreground, waits for Karpenter/CNPG/etc. to fully drain)..."
kubectl delete application root -n argocd --cascade=foreground --wait --timeout="$TIMEOUT"
echo "ARGO-DOWN: cascade complete."
