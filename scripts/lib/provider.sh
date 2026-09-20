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
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc backups}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent-civo}"
elif [ "$PROVIDER" = "hetzner" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-hetzner-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-hz}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster-hetzner}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-persistent-hetzner}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-acm}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent}"
else
  export PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
  export SUBDOMAIN="${SUBDOMAIN:-lab}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster}"
  export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-eks}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent}"
fi

# One negated --filter per unit named in PERSISTENT_EXCLUDE, one argument per line.
persistent_exclude_filters() {
  local unit
  for unit in $PERSISTENT_EXCLUDE; do
    printf -- '--filter\n!./%s\n' "$unit"
  done
}

# Decrypts the Civo API token and exports it as CIVO_TOKEN. Masks it in
# GitHub Actions logs; never echoes it anywhere else.
civo_token() {
  local token
  token="$(SECRET_SCOPE=global "$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" civo-token)"
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

# Decrypts the Hetzner API token and exports it as HCLOUD_TOKEN. Masks it in
# GitHub Actions logs; never echoes it anywhere else.
hcloud_token() {
  local token
  token="$(SECRET_SCOPE=global "$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" hetzner-token)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi
  export HCLOUD_TOKEN="$token"
}

# hcloud is stateless with HCLOUD_TOKEN set; an empty config keeps a stray
# operator context out of the run, and nothing is ever written to disk.
hcloud_cli() {
  HCLOUD_CONFIG=/dev/null hcloud "$@"
}

# Names of this project's <resource>s, narrowed by extra key=value label terms.
# CLIs before 1.55 print null rather than [] for an empty list.
hcloud_list_names() {
  local resource="$1" selector="project=$PROJECT_NAME"
  shift
  if [ $# -gt 0 ]; then
    selector="$selector,$(IFS=,; printf '%s' "$*")"
  fi
  hcloud_cli "$resource" list -o json -l "$selector" | jq -r '(. // [])[].name'
}

cluster_exists() {
  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    civo_cli kubernetes show "$CLUSTER_NAME" --region "$CIVO_REGION" >/dev/null 2>&1
  else
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$LAB_REGION" >/dev/null 2>&1
  fi
}

# Points this process's kubectl and helm at a repo-local kubeconfig instead of
# the operator's own, so a lifecycle run never changes the context they work in.
use_isolated_kubeconfig() {
  local path="${1:-.kube/${PROJECT_NAME}.config}"
  case "$path" in
    /*) ;;
    *) path="$PROVIDER_SH_REPO_ROOT/$path" ;;
  esac
  mkdir -p "$(dirname "$path")"
  # Deliberately not exported: an inherited marker would let the guard pass in a
  # shell that never called this function. KUBECONFIG is exported, for kubectl.
  LAB_KUBECONFIG="$path"
  export KUBECONFIG="$path"
}

# An unqualified kubectl call outside isolation reaches whatever cluster the
# operator selected. An empty-string check is not enough - they can export
# KUBECONFIG for their own session.
require_isolated_kubeconfig() {
  if [ -z "${LAB_KUBECONFIG:-}" ] || [ "${KUBECONFIG:-}" != "$LAB_KUBECONFIG" ]; then
    echo "${FUNCNAME[1]:-this function} runs kubectl: call use_isolated_kubeconfig first" >&2
    return 1
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
      civo_cli kubernetes config "$CLUSTER_NAME" --save --local-path "$kubeconfig" --region "$CIVO_REGION" >/dev/null || return 1
    else
      civo_cli kubernetes config "$CLUSTER_NAME" --save --region "$CIVO_REGION" >/dev/null || return 1
    fi
    local raw_context
    raw_context="$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]')"
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config delete-context "${PROJECT_NAME}-civo" >/dev/null 2>&1 || true
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config rename-context "$raw_context" "${PROJECT_NAME}-civo" >/dev/null
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config use-context "${PROJECT_NAME}-civo" >/dev/null
  elif [ "$PROVIDER" = "hetzner" ]; then
    echo "configure_kubeconfig: PROVIDER=hetzner is implemented in HETZ-040" >&2
    return 1
  else
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "$CLUSTER_NAME" \
      --role-arn "$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)" \
      ${kcfg[@]:+"${kcfg[@]}"} >/dev/null || return 1
  fi
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context --current --namespace=default >/dev/null
}

# True once the API server answers, retrying through a transient outage rather
# than refusing on one bad probe. Teardown's callers abort when this fails, so
# a single blip would otherwise orphan load balancers and nodes - and a blip is
# most likely exactly here, right after a node pool resize.
api_reachable() {
  local attempts="${API_REACHABLE_ATTEMPTS:-6}" interval="${API_REACHABLE_INTERVAL:-10}" i=1
  while [ "$i" -le "$attempts" ]; do
    if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
      [ "$i" -gt 1 ] && echo "API reachable again after $i attempts." >&2
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$interval"
    i=$((i + 1))
  done
  return 1
}

# On AWS, eks-test-identity maps to the read-only role through its EKS access
# entry. Civo has no IAM to map a read-only identity, so the E2E suite gets a
# short-lived token for the e2e-test ServiceAccount, minted as cluster-admin.
configure_test_kubeconfig() {
  local kubeconfig="${1:-}"
  local kcfg=()
  [ -n "$kubeconfig" ] && kcfg=(--kubeconfig "$kubeconfig")

  if [ "$PROVIDER" = "hetzner" ]; then
    echo "configure_test_kubeconfig: PROVIDER=hetzner is implemented in HETZ-130" >&2
    return 1
  fi
  if [ "$PROVIDER" != "civo" ]; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "${CLUSTER_NAME}-test" \
      --role-arn "$(aws iam get-role --role-name eks-test-identity --query Role.Arn --output text)" \
      ${kcfg[@]:+"${kcfg[@]}"} >/dev/null || return 1
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context --current --namespace=default >/dev/null
    return
  fi

  local admin_context="${PROJECT_NAME}-civo" test_context="${PROJECT_NAME}-civo-test"
  local cluster token
  configure_kubeconfig "$kubeconfig"
  cluster="$(kubectl ${kcfg[@]:+"${kcfg[@]}"} config view -o jsonpath="{.contexts[?(@.name==\"$admin_context\")].context.cluster}")"
  if [ -z "$cluster" ]; then
    echo "configure_test_kubeconfig: kubeconfig has no context $admin_context" >&2
    return 1
  fi
  if ! token="$(kubectl ${kcfg[@]:+"${kcfg[@]}"} --context "$admin_context" create token e2e-test -n e2e --duration=1h)"; then
    echo "configure_test_kubeconfig: cannot create a token for ServiceAccount e2e/e2e-test - has 'make argo-up' synced the platform?" >&2
    return 1
  fi
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-credentials "$test_context" --token="$token" >/dev/null
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context "$test_context" --cluster="$cluster" --user="$test_context" --namespace=default >/dev/null
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config use-context "$test_context" >/dev/null
}

# The previous bring-up's serverName, read from the given SSM layer. Absent on
# the first bring-up; empty means there is nothing to recover from.
backup_recovery_handle() {
  local value
  value="$(aws ssm get-parameter --region "$LAB_REGION" \
    --name "/$PROJECT_NAME/$1/postgres-backup/server_name" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ "$value" = "None" ] && value=""
  printf '%s' "$value"
}

# Best effort by design: continuous WAL archiving already made every committed
# row durable before teardown started, so a failed final base backup costs
# replay time, not data. Aborting here would leave a paid cluster running.
backup_teardown() {
  require_isolated_kubeconfig || return 1
  local ns=cnpg-system
  if ! kubectl get cluster lab-postgres -n "$ns" >/dev/null 2>&1; then
    echo "ARGO-DOWN: no lab-postgres Cluster found - nothing to back up."
    return 0
  fi

  # Read before anything is attempted, not after a failure: this is what
  # decides whether a best-effort backup is a safe choice or a loud warning
  # that writes are about to be destroyed.
  local archiving
  archiving="$(backup_archiving_status "$ns")"
  if [ "$archiving" != "True" ]; then
    {
      echo "ARGO-DOWN: WARNING - WAL archiving is not healthy (ContinuousArchiving=${archiving:-unknown})."
      echo "ARGO-DOWN: WARNING - writes made since it stopped have NOT reached S3 and are destroyed by this teardown."
      echo "ARGO-DOWN: WARNING - $(backup_archiving_since "$ns")"
      echo "ARGO-DOWN: WARNING - the pre-teardown backup is attempted anyway, but do not rely on it."
    } >&2
  fi

  local poll="${ARGO_DOWN_POLL_INTERVAL:-5}"
  local timeout="${ARGO_DOWN_BACKUP_TIMEOUT:-600s}"
  timeout="${timeout%s}"

  # Closes the window between the last row written and the last segment
  # archived: without this the tail of WAL sits in an unarchived partial
  # segment that dies with the volume.
  local primary
  primary="$(kubectl get pod -n "$ns" -l cnpg.io/cluster=lab-postgres,cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$primary" ]; then
    echo "ARGO-DOWN: forcing a WAL switch on $primary so the final segment is archived..."
    kubectl exec "$primary" -n "$ns" -c postgres -- \
      psql -U postgres -tAc 'select pg_switch_wal()' >/dev/null 2>&1 \
      || echo "ARGO-DOWN: WARNING - could not force a WAL switch; continuing." >&2
  else
    echo "ARGO-DOWN: WARNING - no primary pod found for lab-postgres; skipping the WAL switch." >&2
  fi

  local backup_name
  backup_name="lab-postgres-teardown-$(date +%s 2>/dev/null || echo manual)"
  echo "ARGO-DOWN: creating a pre-teardown plugin backup ($backup_name)..."
  if ! kubectl apply -f - <<EOF >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup_name
  namespace: $ns
spec:
  cluster:
    name: lab-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  then
    backup_teardown_warn "$ns" "the Backup object could not be created"
    return 0
  fi

  local elapsed=0 phase
  while true; do
    phase="$(kubectl get backup "$backup_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "ARGO-DOWN: backup phase: ${phase:-pending} (${elapsed}s/${timeout}s)"
    if [ "$phase" = "completed" ]; then
      echo "ARGO-DOWN: pre-teardown backup completed."
      return 0
    fi
    if [ "$phase" = "failed" ]; then
      backup_teardown_warn "$ns" "Backup/$backup_name reported phase 'failed'"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      backup_teardown_warn "$ns" "Backup/$backup_name did not complete within ${timeout}s"
      return 0
    fi
    sleep "$poll"
    elapsed=$((elapsed + poll))
  done
}

# CNPG's Cluster status carries no last-archived segment name, so this
# condition is the only thing that says whether committed rows reached S3.
backup_archiving_status() {
  kubectl get cluster lab-postgres -n "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}' \
    2>/dev/null || true
}

backup_archiving_since() {
  local since
  since="$(kubectl get cluster lab-postgres -n "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.lastTransitionTime}{end}' \
    2>/dev/null || true)"
  if [ -n "$since" ]; then
    echo "The unarchived window starts at $since."
  else
    echo "The start of the unarchived window is unknown."
  fi
}

backup_teardown_warn() {
  local ns="$1" reason="$2"
  {
    echo "ARGO-DOWN: WARNING - the pre-teardown Postgres backup did not complete: $reason."
    echo "ARGO-DOWN: WARNING - ContinuousArchiving=$(backup_archiving_status "$ns"). $(backup_archiving_since "$ns")"
    echo "ARGO-DOWN: WARNING - teardown continues. Rows committed while archiving was True are already in S3;"
    echo "ARGO-DOWN: WARNING - recovery will replay from the last base backup and cost extra time, not data."
    echo "ARGO-DOWN: WARNING - inspect with 'kubectl describe cluster lab-postgres -n $ns' before the next bring-up."
  } >&2
}

# Exports the whole Secret, not just cert/key fields, to preserve its
# cert-manager.io/* annotations and avoid a spurious reissue on next import.
# A missing Secret is not an error - first-ever run, argo-up bootstraps fresh.
civo_export_tls_secret() {
  require_isolated_kubeconfig || return 1
  if ! kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-DOWN: no platform-public-tls Secret found - nothing to export."
    return 0
  fi
  local manifest
  manifest="$(kubectl get secret platform-public-tls -n envoy -o yaml \
    | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields,
              .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])')"
  # Best effort: a failed export costs one ACME order on the next argo-up,
  # while aborting here would leave the whole cluster running.
  if aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/civo/tls/platform-public" \
    --type SecureString \
    --tier Advanced \
    --key-id alias/lab-secrets \
    --overwrite \
    --value "$manifest" >/dev/null; then
    echo "ARGO-DOWN: exported platform-public-tls Secret to SSM (${#manifest} chars)."
  else
    echo "ARGO-DOWN: WARNING - could not store platform-public-tls in SSM (${#manifest} chars, limit 8192) - the next argo-up orders a fresh certificate." >&2
  fi
}

# Restoring before the root Application creates the Certificate avoids a
# redundant ACME order. A cert already past its renewal time is skipped -
# importing it would just trigger an immediate reissue anyway.
civo_import_tls_secret() {
  require_isolated_kubeconfig || return 1
  if kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-UP: platform-public-tls Secret already present - leaving the live one alone."
    return 0
  fi

  local manifest
  manifest="$(aws ssm get-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/civo/tls/platform-public" \
    --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -z "$manifest" ] || [ "$manifest" = "None" ]; then
    echo "ARGO-UP: no stored platform-public-tls Secret in SSM - a fresh certificate will be ordered."
    return 0
  fi

  # cert-manager keeps notAfter/renewalTime on the Certificate, not the Secret,
  # so read the leaf's own expiry. Inside the default renewal window (last 30
  # days) an import only triggers an immediate renewal order anyway.
  local not_after not_after_epoch now_epoch
  not_after="$(echo "$manifest" | yq '.data["tls.crt"] // ""' | base64 -d 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -n "$not_after" ]; then
    not_after_epoch="$(date -u -d "$not_after" +%s 2>/dev/null \
      || date -u -jf "%b %e %H:%M:%S %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    if [ "$not_after_epoch" -gt 0 ] && [ $((not_after_epoch - now_epoch)) -le $((30 * 24 * 3600)) ]; then
      echo "ARGO-UP: stored platform-public-tls certificate expires $not_after (inside the renewal window) - skipping import, a fresh certificate will be ordered."
      return 0
    fi
  fi

  kubectl create namespace envoy --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Server-side apply: client-side apply would stamp a last-applied annotation
  # holding a full copy of the Secret, doubling the next export past 8 KiB.
  echo "$manifest" | kubectl apply --server-side --force-conflicts -f - >/dev/null
  echo "ARGO-UP: restored platform-public-tls Secret from SSM (not-after: ${not_after:-unknown})."
}
