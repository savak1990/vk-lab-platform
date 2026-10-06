# The credential Ahorro's pipeline deploys with, republished on every
# bring-up. The cluster is disposable: a new one mints a new CA and new
# tokens, so a kubeconfig stored anywhere durable is wrong by the next
# `make up`. SSM is the one place both sides already reach.
#
# Sourced by argo-up.sh. Expects PROJECT_NAME, PROVIDER and LAB_REGION, and a
# kubeconfig whose current context is cluster-admin.

AHORRO_DEPLOY_SA_NAMESPACE="ahorro-dev"
AHORRO_DEPLOY_SA_NAME="ahorro-deploy"
# Longer than any lab cluster lives. The API server caps it at its own
# --service-account-max-token-expiration and says so in a warning, which is
# why the granted expiry is echoed rather than assumed.
AHORRO_DEPLOY_TOKEN_DURATION="${AHORRO_DEPLOY_TOKEN_DURATION:-8760h}"

ahorro_deploy_ssm_prefix() {
  printf '/%s/cluster/ahorro-deploy' "$PROJECT_NAME"
}

ahorro_deploy_put() {
  local name="$1"
  local value="$2"
  local type="$3"
  local key_args=()
  [ "$type" = SecureString ] && key_args=(--key-id alias/lab-secrets --tier Advanced)

  # Guarded, unlike backup_publish_server_name: under `set -euo pipefail` an
  # unguarded put-parameter turns a transient SSM failure into a failed
  # bring-up, and a missing deploy credential is not worth that.
  if aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "$(ahorro_deploy_ssm_prefix)/$name" \
    --type "$type" \
    ${key_args[@]:+"${key_args[@]}"} \
    --overwrite \
    --value "$value" >/dev/null; then
    return 0
  fi
  echo "AHORRO-DEPLOY: could not write $(ahorro_deploy_ssm_prefix)/$name - the application's pipeline will not reach this cluster until the next argo-up." >&2
  return 1
}

# Called from both arms of argo-up.sh. The fast path exits before the end of
# that script, so a run that synced but died before publishing would otherwise
# leave the parameters missing for ever behind a healthy-looking cluster.
ahorro_publish_deploy_credential() {
  if [ "$PROVIDER" = local ]; then
    echo "AHORRO-DEPLOY: skipped on local - no pipeline deploys to kind."
    return 0
  fi

  local context cluster server ca token
  context="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$context" ]; then
    echo "AHORRO-DEPLOY: no current kubeconfig context - skipping." >&2
    return 1
  fi
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context\")].context.cluster}")"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}")"
  ca="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority-data}")"
  if [ -z "$server" ] || [ -z "$ca" ]; then
    echo "AHORRO-DEPLOY: kubeconfig context $context has no server or CA - skipping." >&2
    return 1
  fi

  if ! token="$(kubectl create token "$AHORRO_DEPLOY_SA_NAME" \
    -n "$AHORRO_DEPLOY_SA_NAMESPACE" \
    --duration="$AHORRO_DEPLOY_TOKEN_DURATION" 2>/dev/null)"; then
    echo "AHORRO-DEPLOY: cannot mint a token for $AHORRO_DEPLOY_SA_NAMESPACE/$AHORRO_DEPLOY_SA_NAME - has the platform synced?" >&2
    return 1
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi

  ahorro_deploy_put endpoint "$server" String || return 1
  ahorro_deploy_put ca "$ca" String || return 1
  ahorro_deploy_put token "$token" SecureString || return 1

  echo "AHORRO-DEPLOY: published the deploy credential to $(ahorro_deploy_ssm_prefix)/ (requested $AHORRO_DEPLOY_TOKEN_DURATION)."
}
