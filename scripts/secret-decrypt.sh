#!/usr/bin/env bash
# Decrypts secrets/<name>.enc and prints the plaintext to stdout.
# Usage: scripts/secret-decrypt.sh <name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

NAME="${1:-}"

test -n "$NAME" || { echo "Usage: scripts/secret-decrypt.sh <name>"; exit 1; }

# root-domain is account-global, not per-project - see secrets/README.md.
if [ "$NAME" = "root-domain" ]; then
  SECRET_FILE="$REPO_ROOT/secrets/$NAME.enc"
else
  SECRET_FILE="$REPO_ROOT/secrets/$PROJECT_NAME/$NAME.enc"
fi
test -f "$SECRET_FILE" || { echo "$SECRET_FILE does not exist"; exit 1; }

aws kms decrypt \
  --region "$ACCOUNT_MAIN_REGION" \
  --ciphertext-blob "fileb://$SECRET_FILE" \
  --output text \
  --query Plaintext | base64 --decode
