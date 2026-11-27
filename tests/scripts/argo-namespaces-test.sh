#!/usr/bin/env bash
# Pins vkllm_namespaces(), the function argo-up.sh uses to build Argo's
# application.namespaces from gitops/values.yaml - both on the idempotency
# fast path and inside install_argocd. Needs no credentials and no cluster.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0

# Just the function, so sourcing argo-up.sh's top level never happens.
eval "$(awk '/^vkllm_namespaces\(\) \{/,/^\}/' "$REPO_ROOT/scripts/argo-up.sh")"

got="$(vkllm_namespaces "$REPO_ROOT/gitops/values.yaml")"
want='llm\,llm-dev'
if [ "$got" != "$want" ]; then
  echo "FAIL: vkllm_namespaces gave '$got', expected '$want'"
  fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] || {
  echo "$fails failure(s)"
  exit 1
}
echo "vkllm_namespaces reads gitops/values.yaml's instances in list order"
