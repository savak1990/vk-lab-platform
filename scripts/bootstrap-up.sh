#!/usr/bin/env bash
# Creates Bootstrap-lifecycle resources (the secrets KMS key).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT/terraform/live/bootstrap"

# A cache left over from a previous run against a different
# PROJECT_NAME/REGION bakes its old backend config into the cached working
# directory, which then makes `terraform apply` refuse to proceed
# ("Backend configuration has changed"). Clear it unconditionally so every
# run starts from a clean init.
find . -type d -name .terragrunt-cache -prune -exec rm -rf {} +

terragrunt run --all apply --non-interactive
