#!/usr/bin/env bash
# Generates secrets/$PROJECT_NAME/{root-domain,postgres-admin-password,
# postgres-app-password}.enc for a throwaway CI/test project - the fixed
# Postgres passwords are known values, never meant for the personal lab's
# own PROJECT_NAME. Requires bootstrap (the KMS key) to already exist for
# PROJECT_NAME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DOMAIN="${ROOT_DOMAIN:-}"

test -n "$ROOT_DOMAIN" || { echo "Usage: ROOT_DOMAIN=<domain> scripts/generate-secrets.sh"; exit 1; }

SECRET_NAME=root-domain SECRET_VALUE="$ROOT_DOMAIN" "$SCRIPT_DIR/secret-encrypt.sh"
SECRET_NAME=postgres-admin-password SECRET_VALUE=test "$SCRIPT_DIR/secret-encrypt.sh"
SECRET_NAME=postgres-app-password SECRET_VALUE=test "$SCRIPT_DIR/secret-encrypt.sh"
