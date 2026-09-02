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
# Two modes, chosen by FIXED_TEST_PASSWORDS:
#   - unset/false (default, the real lab): passwords get real random
#     values via AWS Secrets Manager. Called automatically by persistent-up.
#   - true (CI/test, via `make generate-secrets`): passwords get the
#     fixed, publicly-known value "test" - never use this for the
#     personal lab's own PROJECT_NAME.
# root-domain.enc is never randomly generated either way - it's a real
# external domain value. It's generated from $ROOT_DOMAIN if that's set
# and the file is still missing; otherwise this script leaves it alone and
# require-persistent-secrets.sh (the next persistent-up step) is what
# actually fails the build with an actionable error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"
FIXED_TEST_PASSWORDS="${FIXED_TEST_PASSWORDS:-false}"
source "$SCRIPT_DIR/lib/region.sh"

random_password() {
  aws secretsmanager get-random-password --region "$PROJECT_REGION" --exclude-punctuation \
    --password-length 32 --output text --query RandomPassword
}

# root-domain is account-global, filed under secrets/ directly rather than
# secrets/$PROJECT_NAME/ - see secret-encrypt.sh.
generate_if_missing() {
  local name="$1" value="$2"
  local file="$REPO_ROOT/secrets/root-domain.enc"
  [ "$name" = "root-domain" ] || file="$SECRETS_DIR/$name.enc"
  if [ -f "$file" ]; then
    echo "Skipping $name - $file already exists"
  else
    SECRET_NAME="$name" SECRET_VALUE="$value" "$SCRIPT_DIR/secret-encrypt.sh"
  fi
}

# Password value is only computed (an AWS API call, in the random case) if
# the file is actually missing - never wasted on an already-generated one.
generate_password_if_missing() {
  local name="$1"
  if [ -f "$SECRETS_DIR/$name.enc" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.enc already exists"
    return
  fi
  local value
  if [ "$FIXED_TEST_PASSWORDS" = "true" ]; then
    value=test
  else
    value="$(random_password)"
  fi
  SECRET_NAME="$name" SECRET_VALUE="$value" "$SCRIPT_DIR/secret-encrypt.sh"
}

if [ -n "$ROOT_DOMAIN" ]; then
  generate_if_missing root-domain "$ROOT_DOMAIN"
fi

generate_password_if_missing postgres-app-password
generate_password_if_missing grafana-admin-password

# argocd-admin-password.bcrypt is plaintext-committed (not KMS-encrypted -
# secret-encrypt.sh doesn't apply, see secrets/README.md), generated in
# both modes so CI gets the same reproducible "test" login as it does for
# Postgres/Grafana.
generate_bcrypt_if_missing() {
  local name="$1"
  if [ -f "$SECRETS_DIR/$name.bcrypt" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.bcrypt already exists"
    return
  fi
  local plaintext
  if [ "$FIXED_TEST_PASSWORDS" = "true" ]; then
    plaintext=test
  else
    plaintext="$(random_password)"
  fi
  mkdir -p "$SECRETS_DIR"
  htpasswd -nbBC 10 "" "$plaintext" | cut -d: -f2 | tr -d '\n' > "$SECRETS_DIR/$name.bcrypt.tmp"
  mv "$SECRETS_DIR/$name.bcrypt.tmp" "$SECRETS_DIR/$name.bcrypt"
  echo "Generated $name.bcrypt"
}

generate_bcrypt_if_missing argocd-admin-password
