#!/usr/bin/env bash
# Generates secrets/$PROJECT_NAME/{root-domain,postgres-app-password}.enc
# for a throwaway CI/test project - the fixed Postgres password is a known
# value, never meant for the personal lab's own PROJECT_NAME. Requires
# bootstrap (the KMS key) to already exist for PROJECT_NAME. Leaves any
# secret that already exists untouched, rather than overwriting it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"

test -n "$ROOT_DOMAIN" || { echo "Usage: ROOT_DOMAIN=<domain> scripts/generate-secrets.sh"; exit 1; }

generate_if_missing() {
  local name="$1" value="$2"
  if [ -f "$SECRETS_DIR/$name.enc" ]; then
    echo "Skipping $name - $SECRETS_DIR/$name.enc already exists"
  else
    SECRET_NAME="$name" SECRET_VALUE="$value" "$SCRIPT_DIR/secret-encrypt.sh"
  fi
}

generate_if_missing root-domain "$ROOT_DOMAIN"
generate_if_missing postgres-app-password test
