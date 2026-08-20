#!/usr/bin/env bash
# Encrypts a value into secrets/$PROJECT_NAME/<name>.enc using the
# bootstrap KMS key. NAME/VALUE come from the environment
# (SECRET_NAME/SECRET_VALUE), not argv, so an unusual VALUE never has to
# survive shell command-line parsing.
# Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-eu-west-1}"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
KMS_KEY="alias/${PROJECT_NAME}-secrets"

NAME="${SECRET_NAME:-}"
VALUE="${SECRET_VALUE:-}"

test -n "$NAME" || { echo "Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }
test -n "$VALUE" || { echo "Usage: SECRET_NAME=<name> SECRET_VALUE=<value> scripts/secret-encrypt.sh"; exit 1; }

mkdir -p "$REPO_ROOT/secrets/$PROJECT_NAME"

DEST="$REPO_ROOT/secrets/$PROJECT_NAME/$NAME.enc"
TMP="$(mktemp "$DEST.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

printf '%s' "$VALUE" | aws kms encrypt \
  --key-id "$KMS_KEY" \
  --region "$REGION" \
  --plaintext fileb:///dev/stdin \
  --output text \
  --query CiphertextBlob | base64 --decode > "$TMP"

mv "$TMP" "$DEST"
trap - EXIT

echo "Wrote secrets/$PROJECT_NAME/$NAME.enc"
