#!/usr/bin/env bash
# Encrypts a value into secrets/$PROJECT_NAME/<name>.enc (SECRET_SCOPE=project,
# the default) or secrets/<name>.enc (SECRET_SCOPE=global, one value shared by
# every PROJECT_NAME in the account) using the shared, account-global KMS key
# (alias/lab-secrets, created by account-up - not per-project). NAME/VALUE/SCOPE
# come from the environment (SECRET_NAME/SECRET_VALUE/SECRET_SCOPE), not argv,
# so an unusual VALUE never has to survive shell command-line parsing.
# Usage: [SECRET_SCOPE=global] SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/secret-scope.sh"
KMS_KEY="alias/lab-secrets"

NAME="${SECRET_NAME:-}"
VALUE="${SECRET_VALUE:-}"

test -n "$NAME" || { echo "Usage: [SECRET_SCOPE=global] SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }
test -n "$VALUE" || { echo "Usage: [SECRET_SCOPE=global] SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }

SCOPE="$(secret_scope)"
DEST="$(secret_path "$NAME" "$SCOPE")"
mkdir -p "$(dirname "$DEST")"
TMP="$(mktemp "$DEST.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

printf '%s' "$VALUE" | aws kms encrypt \
  --key-id "$KMS_KEY" \
  --region "$LAB_ACCOUNT_REGION" \
  --plaintext fileb:///dev/stdin \
  --output text \
  --query CiphertextBlob | base64 --decode > "$TMP"

mv "$TMP" "$DEST"
trap - EXIT

echo "Wrote ${DEST#$REPO_ROOT/}"
