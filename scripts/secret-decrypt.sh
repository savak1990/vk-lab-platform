#!/usr/bin/env bash
# Decrypts secrets/<name>.enc and prints the plaintext to stdout.
# Usage: scripts/secret-decrypt.sh <name>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${REGION:-eu-west-1}"

NAME="${1:-}"

test -n "$NAME" || { echo "Usage: scripts/secret-decrypt.sh <name>"; exit 1; }
test -f "$REPO_ROOT/secrets/$NAME.enc" || { echo "secrets/$NAME.enc does not exist"; exit 1; }

aws kms decrypt \
  --region "$REGION" \
  --ciphertext-blob "fileb://$REPO_ROOT/secrets/$NAME.enc" \
  --output text \
  --query Plaintext | base64 --decode
