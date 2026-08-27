#!/usr/bin/env bash
# Fails fast if the secrets persistent-up needs for this PROJECT_NAME
# don't exist yet. Without this, a missing secrets/$PROJECT_NAME/*.enc
# file only surfaces as a raw Terraform filebase64() error, deep inside a
# terragrunt run --all apply, after other units may have already partly
# applied.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
SECRETS_DIR="$REPO_ROOT/secrets/$PROJECT_NAME"

missing=()
for name in root-domain postgres-app-password grafana-admin-password; do
  test -f "$SECRETS_DIR/$name.enc" || missing+=("$name")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing secret(s) for PROJECT_NAME=$PROJECT_NAME:" >&2
  for name in "${missing[@]}"; do
    echo "  - $SECRETS_DIR/$name.enc" >&2
  done
  echo "Create them first, e.g.:" >&2
  for name in "${missing[@]}"; do
    echo "  PROJECT_NAME=$PROJECT_NAME make secret-encrypt NAME=$name VALUE=<value>" >&2
  done
  exit 1
fi
