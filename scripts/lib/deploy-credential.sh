# Republished on every bring-up for each application in gitops/values.yaml
# deployCredentials. The cluster is disposable: a new one mints a new CA and
# new tokens, so a kubeconfig stored anywhere durable is wrong by the next
# `make up`. SSM is the one place both sides already reach.
#
# Sourced by argo-up.sh and argo-down.sh. Expects REPO_ROOT, PROJECT_NAME,
# PROVIDER and LAB_REGION, and a kubeconfig whose current context is cluster-admin.

DEPLOY_CREDENTIAL_TOKEN_DURATION="${DEPLOY_CREDENTIAL_TOKEN_DURATION:-8760h}"

deploy_credential_ssm_prefix() {
  printf '/%s/cluster/%s-deploy' "$PROJECT_NAME" "$1"
}

# "<app> <home namespace>" per line.
deploy_credential_apps() {
  yq -r '.deployCredentials[] | .app + " " + .namespaces[0]' "$REPO_ROOT/gitops/values.yaml"
}

deploy_credential_put() {
  local app="$1" name="$2" value="$3" type="$4"
  local key_args=()
  [ "$type" = SecureString ] && key_args=(--key-id alias/lab-secrets --tier Advanced)
  # Guarded: under `set -euo pipefail` an unguarded put-parameter would turn a
  # transient SSM failure into a failed bring-up, and a missing deploy
  # credential is not worth that.
  if aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "$(deploy_credential_ssm_prefix "$app")/$name" \
    --type "$type" \
    ${key_args[@]:+"${key_args[@]}"} \
    --overwrite \
    --value "$value" >/dev/null; then
    return 0
  fi
  echo "DEPLOY-CREDENTIAL: could not write $(deploy_credential_ssm_prefix "$app")/$name - $app's pipeline will not reach this cluster until the next argo-up." >&2
  return 1
}

deploy_credential_publish() {
  local app="$1" sa_namespace="$2" sa_name="$1-deploy"
  if [ "$PROVIDER" = local ]; then
    echo "DEPLOY-CREDENTIAL: skipped $app on local - no pipeline deploys to kind."
    return 0
  fi
  local context cluster server ca token
  context="$(kubectl config current-context 2>/dev/null || true)"
  if [ -z "$context" ]; then
    echo "DEPLOY-CREDENTIAL: no current kubeconfig context - skipping $app." >&2
    return 1
  fi
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$context\")].context.cluster}")"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.server}")"
  ca="$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"$cluster\")].cluster.certificate-authority-data}")"
  if [ -z "$server" ] || [ -z "$ca" ]; then
    echo "DEPLOY-CREDENTIAL: kubeconfig context $context has no server or CA - skipping $app." >&2
    return 1
  fi

  if ! token="$(kubectl create token "$sa_name" -n "$sa_namespace" \
    --duration="$DEPLOY_CREDENTIAL_TOKEN_DURATION" 2>/dev/null)"; then
    echo "DEPLOY-CREDENTIAL: cannot mint a token for $sa_namespace/$sa_name - has the platform synced?" >&2
    return 1
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi

  deploy_credential_put "$app" endpoint "$server" String || return 1
  deploy_credential_put "$app" ca "$ca" String || return 1
  deploy_credential_put "$app" token "$token" SecureString || return 1

  # The pipeline builds its own hostnames; its CI role can read this prefix
  # but not the fqdn parameter itself. Never echoed.
  if [ -n "${LAB_FQDN:-}" ]; then
    deploy_credential_put "$app" fqdn "$LAB_FQDN" String || return 1
  else
    echo "DEPLOY-CREDENTIAL: no LAB_FQDN in scope - $app's pipeline cannot build hostnames until the next argo-up." >&2
  fi

  echo "DEPLOY-CREDENTIAL: published $app's deploy credential to $(deploy_credential_ssm_prefix "$app")/ (requested $DEPLOY_CREDENTIAL_TOKEN_DURATION)."
}

deploy_credential_forget() {
  local app="$1" name
  [ "$PROVIDER" = local ] && return 0
  for name in token ca endpoint fqdn; do
    aws ssm delete-parameter --region "$LAB_REGION" \
      --name "$(deploy_credential_ssm_prefix "$app")/$name" >/dev/null 2>&1 || true
  done
  echo "DEPLOY-CREDENTIAL: removed $app's deploy credential."
}

# Called from both arms of argo-up.sh: the fast path exits before the end of
# that script, so a run that synced but died before publishing would
# otherwise leave the parameters missing for ever behind a healthy cluster.
deploy_credential_publish_all() {
  local app ns
  while read -r app ns; do
    deploy_credential_publish "$app" "$ns" || true
  done < <(deploy_credential_apps)
}

# Called from cluster teardown: a parameter that outlives its cluster is
# worse than a missing one, since the pipeline builds a kubeconfig that
# looks valid and times out instead of failing fast.
deploy_credential_forget_all() {
  local app _ns
  while read -r app _ns; do
    deploy_credential_forget "$app"
  done < <(deploy_credential_apps)
}
