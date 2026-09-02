#!/usr/bin/env bash
# Decrypts secrets/<name>.enc and prints the plaintext to stdout.
# Usage: scripts/secret-decrypt.sh <name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
# The shared KMS key lives in one fixed region (wherever account-up ran),
# independent of PROJECT_NAME's own PROJECT_REGION - see root.hcl's account_main_region.
ACCOUNT_MAIN_REGION="${ACCOUNT_MAIN_REGION:-eu-west-1}"

NAME="${1:-}"

test -n "$NAME" || { echo "Usage: scripts/secret-decrypt.sh <name>"; exit 1; }
test -f "$REPO_ROOT/secrets/$PROJECT_NAME/$NAME.enc" || { echo "secrets/$PROJECT_NAME/$NAME.enc does not exist"; exit 1; }

aws kms decrypt \
  --region "$ACCOUNT_MAIN_REGION" \
  --ciphertext-blob "fileb://$REPO_ROOT/secrets/$PROJECT_NAME/$NAME.enc" \
  --output text \
  --query Plaintext | base64 --decode
