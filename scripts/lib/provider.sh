# shellcheck shell=bash
# Provider defaults mirror the Makefile: PROVIDER selects the project name,
# subdomain, and disposable-cluster stack directory. aws is the default and
# is unchanged from before this variable existed.

PROVIDER_SH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export PROVIDER="${PROVIDER:-aws}"

if [ "$PROVIDER" = "civo" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-civo-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-civo}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster-civo}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-persistent-civo}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-acm}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc}"
else
  export PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
  export SUBDOMAIN="${SUBDOMAIN:-lab}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster}"
  export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-eks}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-}"
fi

# Decrypts the Civo API token and exports it as CIVO_TOKEN. Masks it in
# GitHub Actions logs; never echoes it anywhere else.
civo_token() {
  local token
  token="$("$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" civo-token)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi
  export CIVO_TOKEN="$token"
}

# civo CLI writes token to ~/.civo.json as a side effect; CIVO_CONFIG redirects to throwaway tmpfile.
# || status=$? prevents set -e interference on failure.
civo_cli() {
  local tmp status=0
  tmp="$(mktemp)"
  CIVO_CONFIG="$tmp" civo "$@" || status=$?
  rm -f "$tmp"
  return "$status"
}

# civo <resource> ls -o json returns plain text "No resources..." instead of [] on zero results.
# Check shape before piping to jq to avoid aborting under set -e.
civo_list_names() {
  local resource="$1"
  shift
  local raw
  raw="$(civo_cli "$resource" ls -o json --region "$CIVO_REGION" "$@" 2>/dev/null || true)"
  case "$raw" in
    \[*) echo "$raw" | jq -r '.[].name' ;;
  esac
}

cluster_exists() {
  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    civo_cli kubernetes show "$CLUSTER_NAME" --region "$CIVO_REGION" >/dev/null 2>&1
  else
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$LAB_REGION" >/dev/null 2>&1
  fi
}

# On civo, renames context to ${PROJECT_NAME}-civo (no --context-name flag); deletes target context first
# to guard against reruns. On AWS, uses update-kubeconfig with the eks-access-identity role.
configure_kubeconfig() {
  local kubeconfig="${1:-}"
  local kcfg=()
  [ -n "$kubeconfig" ] && kcfg=(--kubeconfig "$kubeconfig")

  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    if [ -n "$kubeconfig" ]; then
      civo_cli kubernetes config "$CLUSTER_NAME" --save --local-path "$kubeconfig" --region "$CIVO_REGION" >/dev/null
    else
      civo_cli kubernetes config "$CLUSTER_NAME" --save --region "$CIVO_REGION" >/dev/null
    fi
    local raw_context
    raw_context="$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]')"
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config delete-context "${PROJECT_NAME}-civo" >/dev/null 2>&1 || true
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config rename-context "$raw_context" "${PROJECT_NAME}-civo" >/dev/null
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config use-context "${PROJECT_NAME}-civo" >/dev/null
  else
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "$CLUSTER_NAME" \
      --role-arn "$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)" \
      ${kcfg[@]:+"${kcfg[@]}"} >/dev/null
  fi
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context --current --namespace=default >/dev/null
}

# No restore mechanism exists on civo yet, so every argo-up bootstraps fresh.
# Returning empty keeps the call site identical once a real handle lands.
civo_recovery_handle() {
  echo "ARGO-UP: no recovery configured for civo yet (CIVO-120) - bootstrapping fresh." >&2
  printf ''
}

# Fail closed: no backup path exists on civo yet, so refuse to tear down a
# cluster that still holds Postgres data. A missing CNPG CRD means "no
# cluster", not a failed check, hence the two-step probe.
civo_backup() {
  if kubectl get clusters.postgresql.cnpg.io -A >/dev/null 2>&1; then
    if [ -n "$(kubectl get clusters.postgresql.cnpg.io -A -o name 2>/dev/null)" ]; then
      echo "ARGO-DOWN: a CNPG Cluster exists on civo but CIVO-120's backup path isn't implemented yet - refusing to tear down and risk losing Postgres data." >&2
      exit 1
    fi
  fi
  echo "ARGO-DOWN: no CNPG Cluster found on civo - nothing to back up."
}

# Exports the whole Secret, not just cert/key fields, to preserve its
# cert-manager.io/* annotations and avoid a spurious reissue on next import.
# A missing Secret is not an error - first-ever run, argo-up bootstraps fresh.
civo_export_tls_secret() {
  if ! kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-DOWN: no platform-public-tls Secret found - nothing to export."
    return 0
  fi
  local manifest
  manifest="$(kubectl get secret platform-public-tls -n envoy -o yaml \
    | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)')"
  aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/civo/tls/platform-public" \
    --type SecureString \
    --tier Advanced \
    --key-id alias/lab-secrets \
    --overwrite \
    --value "$manifest" >/dev/null
  echo "ARGO-DOWN: exported platform-public-tls Secret to SSM."
}
