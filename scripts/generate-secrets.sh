#!/usr/bin/env bash
# Generates any missing secrets/root-domain.enc and
# secrets/$PROJECT_NAME/{postgres-app-password,grafana-admin-password}.enc
# and argocd-admin-password.bcrypt. Requires
# bootstrap (the KMS key) to already exist for PROJECT_NAME. Leaves any
# secret that already exists untouched, rather than overwriting it -
# postgres-app-password in particular must never be silently regenerated
# once set (ADR 0014/spec 007-2): CNPG's bootstrap.recovery restores
# PGDATA without resetting role passwords, so a new password would desync
# from a recovered database.
#
# Passwords get random values from AWS Secrets Manager. Called automatically
# by persistent-up, and by persistent-down for a checkout that never ran it.
# root-domain.enc is never randomly generated either way - it's a real
# external domain value. It's generated from $ROOT_DOMAIN if that's set
# and the file is still missing; otherwise this script leaves it alone and
# require-persistent-secrets.sh (the next persistent-up step) is what
# actually fails the build with an actionable error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"
source "$SCRIPT_DIR/lib/region.sh"
source "$SCRIPT_DIR/lib/provider.sh"
source "$SCRIPT_DIR/lib/secret-scope.sh"
SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"

random_password() {
  aws secretsmanager get-random-password --region "$LAB_REGION" --exclude-punctuation \
    --password-length 32 --output text --query RandomPassword
}

generate_if_missing() {
  local name="$1" value="$2" scope="$3"
  local file
  file="$(secret_path "$name" "$scope")"
  if [ -f "$file" ]; then
    echo "Skipping $name - $file already exists"
  else
    SECRET_SCOPE="$scope" SECRET_NAME="$name" SECRET_VALUE="$value" "$SCRIPT_DIR/secret-encrypt.sh"
  fi
}

# The AWS call happens only when the file is actually missing.
generate_password_if_missing() {
  local name="$1"
  if [ -f "$SECRETS_DIR/$name.enc" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.enc already exists"
    return
  fi
  SECRET_NAME="$name" SECRET_VALUE="$(random_password)" "$SCRIPT_DIR/secret-encrypt.sh"
}

if [ -n "$ROOT_DOMAIN" ]; then
  generate_if_missing root-domain "$ROOT_DOMAIN" global
fi

generate_password_if_missing postgres-app-password
generate_password_if_missing grafana-admin-password
generate_password_if_missing ahorro-test-user-password

# Every non-EKS target reaches AWS through Roles Anywhere and so needs the
# CA; aws uses Pod Identity and never touches these files.
generate_ca_if_missing() {
  local file="$SECRETS_DIR/${PROVIDER}-ca-cert.pem"
  if [ "$PROVIDER" = "aws" ]; then
    echo "Skipping the workload CA - PROVIDER is aws"
    return
  fi
  if [ -f "$file" ]; then
    echo "Skipping ${PROVIDER}-ca-cert - $file already exists"
    return
  fi
  ROTATE='' PROJECT_NAME="$PROJECT_NAME" "$SCRIPT_DIR/ca-init.sh"
}

generate_ca_if_missing

# Only the Hetzner target boots servers from an SSH key; aws and civo hand
# out cluster access through their own APIs and must not get one.
generate_ssh_key_if_missing() {
  local file="$SECRETS_DIR/hetzner-ssh-key.pub"
  if [ "$PROVIDER" != "hetzner" ]; then
    echo "Skipping the node SSH key - PROVIDER is $PROVIDER"
    return
  fi
  if [ -f "$file" ]; then
    echo "Skipping hetzner-ssh-key - $file already exists"
    return
  fi
  ROTATE='' PROJECT_NAME="$PROJECT_NAME" "$SCRIPT_DIR/ssh-key-init.sh"
}

generate_ssh_key_if_missing

# argocd-admin-password.bcrypt is committed as a hash, so secret-encrypt.sh
# does not apply; only the hash ever reaches SSM and the cluster.
generate_bcrypt_if_missing() {
  local name="$1"
  if [ -f "$SECRETS_DIR/$name.bcrypt" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.bcrypt already exists"
    return
  fi
  local plaintext
  plaintext="$(random_password)"
  mkdir -p "$SECRETS_DIR"
  htpasswd -nbBC 10 "" "$plaintext" | cut -d: -f2 | tr -d '\n' > "$SECRETS_DIR/$name.bcrypt.tmp"
  mv "$SECRETS_DIR/$name.bcrypt.tmp" "$SECRETS_DIR/$name.bcrypt"
  echo "Generated $name.bcrypt"
}

generate_bcrypt_if_missing argocd-admin-password
