#!/usr/bin/env bash
# Encrypts a value into secrets/$PROJECT_NAME/<name>.enc (or secrets/<name>.enc
# for the account-global root-domain) using the shared,
# account-global KMS key (alias/lab-secrets, created by account-up - not
# per-project). NAME/VALUE come from the environment
# (SECRET_NAME/SECRET_VALUE), not argv, so an unusual VALUE never has to
# survive shell command-line parsing.
# Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
KMS_KEY="alias/lab-secrets"

NAME="${SECRET_NAME:-}"
VALUE="${SECRET_VALUE:-}"

test -n "$NAME" || { echo "Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }
test -n "$VALUE" || { echo "Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }

# root-domain is account-global, not per-project - see secrets/README.md.
if [ "$NAME" = "root-domain" ]; then
  DEST="$REPO_ROOT/secrets/$NAME.enc"
else
  mkdir -p "$REPO_ROOT/secrets/$PROJECT_NAME"
  DEST="$REPO_ROOT/secrets/$PROJECT_NAME/$NAME.enc"
fi
TMP="$(mktemp "$DEST.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

printf '%s' "$VALUE" | aws kms encrypt \
  --key-id "$KMS_KEY" \
  --region "$ACCOUNT_MAIN_REGION" \
  --plaintext fileb:///dev/stdin \
  --output text \
  --query CiphertextBlob | base64 --decode > "$TMP"

mv "$TMP" "$DEST"
trap - EXIT

echo "Wrote ${DEST#$REPO_ROOT/}"
