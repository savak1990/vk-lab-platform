#!/usr/bin/env bash
# Generates secrets/$PROJECT_NAME/{root-domain,postgres-app-password}.enc
# for a throwaway CI/test project - the fixed Postgres password is a known
# value, never meant for the personal lab's own PROJECT_NAME. Requires
# bootstrap (the KMS key) to already exist for PROJECT_NAME. Leaves any
# secret that already exists untouched, rather than overwriting it.
#
# Also generates secrets/$PROJECT_NAME/kafka-cluster-id.txt - NOT KMS-
# encrypted (it's a UUID, not a credential, see ADR 0016), so it's written
# directly rather than through secret-encrypt.sh/bootstrap's KMS key.
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

# Plain file, not .enc/KMS - matches the format kafka-storage.sh's own
# random-uuid emits (16 random bytes, base64-urlsafe, no padding), so a
# real Strimzi cluster accepts it identically to a manually generated one.
if [ -f "$SECRETS_DIR/kafka-cluster-id.txt" ]; then
  echo "Skipping kafka-cluster-id.txt - $SECRETS_DIR/kafka-cluster-id.txt already exists"
else
  mkdir -p "$SECRETS_DIR"
  openssl rand 16 | base64 | tr '+/' '-_' | tr -d '=\n' > "$SECRETS_DIR/kafka-cluster-id.txt"
  echo "Generated $SECRETS_DIR/kafka-cluster-id.txt"
fi
