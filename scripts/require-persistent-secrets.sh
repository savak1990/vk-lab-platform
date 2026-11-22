#!/usr/bin/env bash
# Fails fast if the secrets persistent-up needs for this PROJECT_NAME
# don't exist yet. Without this, a missing secrets/$PROJECT_NAME/*.enc
# file only surfaces as a raw Terraform filebase64() error, deep inside a
# terragrunt run --all apply, after other units may have already partly
# applied.
set -euo pipefail

# Read by secret_path in the sourced secret-scope.sh.
# shellcheck disable=SC2034
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/secret-scope.sh"

scope_of() {
  case "$1" in
    root-domain|vast-ai-api-key|llm-on-demand-*) echo global ;;
    *) echo project ;;
  esac
}

missing=()
for name in root-domain postgres-app-password grafana-admin-password ahorro-test-user-password \
            vast-ai-api-key llm-on-demand-api-token llm-on-demand-client-keys \
            llm-on-demand-worker-seed llm-on-demand-ssh-private-key; do
  test -f "$(secret_path "$name" "$(scope_of "$name")")" || missing+=("$name")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "Missing secret(s) for PROJECT_NAME=$PROJECT_NAME:" >&2
  for name in "${missing[@]}"; do
    echo "  - $(secret_path "$name" "$(scope_of "$name")")" >&2
  done
  echo "Create them first, e.g.:" >&2
  for name in "${missing[@]}"; do
    echo "  PROJECT_NAME=$PROJECT_NAME make secret-encrypt NAME=$name VALUE=<value> SCOPE=$(scope_of "$name")" >&2
  done
  exit 1
fi
