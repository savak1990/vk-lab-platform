#!/usr/bin/env bash
# Decrypts secrets/$PROJECT_NAME/<name>.enc (SECRET_SCOPE=project, the default)
# or secrets/<name>.enc (SECRET_SCOPE=global) and prints the plaintext to stdout.
# Usage: [SECRET_SCOPE=global] scripts/secret-decrypt.sh <name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/secret-scope.sh"

NAME="${1:-}"

test -n "$NAME" || { echo "Usage: [SECRET_SCOPE=global] scripts/secret-decrypt.sh <name>"; exit 1; }

SCOPE="$(secret_scope)"
SECRET_FILE="$(secret_path "$NAME" "$SCOPE")"
if [ ! -f "$SECRET_FILE" ]; then
  echo "$SECRET_FILE does not exist" >&2
  # A file under the other scope is the usual cause; say so instead of leaving a hunt.
  OTHER_SCOPE="$([ "$SCOPE" = global ] && echo project || echo global)"
  OTHER_FILE="$(secret_path "$NAME" "$OTHER_SCOPE")"
  if [ -f "$OTHER_FILE" ]; then
    echo "${OTHER_FILE#$REPO_ROOT/} does - use SCOPE=$OTHER_SCOPE" >&2
  fi
  exit 1
fi

aws kms decrypt \
  --region "$LAB_REGION" \
  --ciphertext-blob "fileb://$SECRET_FILE" \
  --output text \
  --query Plaintext | base64 --decode
