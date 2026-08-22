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

if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: cluster unreachable - nothing to cascade, skipping."
  exit 0
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
