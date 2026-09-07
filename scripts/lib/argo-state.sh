# Argo CD isn't Terraform-managed (ADR 0012), so its state can't be read from
# Terraform state the way the other layers can - it has to be read off the live
# cluster. Shared by status.sh (one project) and clusters.sh (every project).
#
# Writes to a caller-supplied kubeconfig, never the operator's default: an
# inventory command that walked N clusters would otherwise leave the next bare
# kubectl pointed at whichever one the loop ended on.
#
# Not sourced standalone - the caller sets LAB_REGION first, then calls
# argo_state <cluster-name> <kubeconfig-path>.

# Cluster-admin access is granted to a fixed account-global identity, so this
# works regardless of which principal created the cluster or which project owns
# it. A caller looping over clusters should resolve this once and export it -
# argo_state is typically run inside $( ), where a cache set here cannot escape.
argo_access_role_arn() {
  if [ -z "${ARGO_ACCESS_ROLE_ARN:-}" ]; then
    ARGO_ACCESS_ROLE_ARN="$(aws iam get-role --role-name eks-access-identity \
      --query Role.Arn --output text 2>/dev/null || true)"
  fi
  echo "$ARGO_ACCESS_ROLE_ARN"
}

# Echoes one of: "unknown (...)", "absent (...)", "present (...)".
argo_state() {
  local cluster="${1:?argo_state: cluster name required}"
  local kubeconfig="${2:?argo_state: kubeconfig path required}"
  local sync_health app_count

  if [ "${PROVIDER:-aws}" = "civo" ]; then
    civo_token
    if ! CLUSTER_NAME="$cluster" configure_kubeconfig "$kubeconfig" >/dev/null 2>&1 \
      || ! kubectl --kubeconfig "$kubeconfig" cluster-info --request-timeout=5s >/dev/null 2>&1; then
      echo "unknown  (cluster unreachable)"
      return
    fi
  else
    local role_arn
    role_arn="$(argo_access_role_arn)"
    [ -n "$role_arn" ] || { echo "unknown  (eks-access-identity not found)"; return; }

    if ! aws eks update-kubeconfig --name "$cluster" --region "$LAB_REGION" \
      --alias "$cluster" --role-arn "$role_arn" --kubeconfig "$kubeconfig" >/dev/null 2>&1 \
      || ! kubectl --kubeconfig "$kubeconfig" cluster-info --request-timeout=5s >/dev/null 2>&1; then
      echo "unknown  (cluster unreachable)"
      return
    fi
  fi

  if ! kubectl --kubeconfig "$kubeconfig" get application root -n argocd >/dev/null 2>&1; then
    echo "absent   (not installed, or torn down by argo-down)"
    return
  fi

  sync_health="$(kubectl --kubeconfig "$kubeconfig" get application root -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  app_count="$(kubectl --kubeconfig "$kubeconfig" get applications -n argocd \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "present  (root ${sync_health:-unknown}, $app_count Application(s) managed)"
}
