#!/usr/bin/env bash
# Encrypts a value into secrets/<name>.enc using the bootstrap KMS key.
# NAME/VALUE come from the environment (SECRET_NAME/SECRET_VALUE), not
# argv, so an unusual VALUE never has to survive shell command-line parsing.
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

printf '%s' "$VALUE" | aws kms encrypt \
  --key-id "$KMS_KEY" \
  --region "$REGION" \
  --plaintext fileb:///dev/stdin \
  --output text \
  --query CiphertextBlob | base64 --decode > "$REPO_ROOT/secrets/$NAME.enc"

echo "Wrote secrets/$NAME.enc"
