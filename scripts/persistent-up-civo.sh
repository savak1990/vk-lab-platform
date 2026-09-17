#!/usr/bin/env bash
# Creates Persistent-lifecycle resources for the Civo target: the AWS
# secrets unit (the VPC is AWS-only, so it is excluded), then the Civo
# network and reserved IP the disposable cluster attaches to. The aws
# target keeps its own inline Makefile recipe, unchanged.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$REPO_ROOT/scripts/lib/provider.sh"

"$REPO_ROOT/scripts/generate-secrets.sh"
"$REPO_ROOT/scripts/require-persistent-secrets.sh"

civo_token

cd "$REPO_ROOT/terraform/live/persistent"
exclude_args=()
while IFS= read -r arg; do exclude_args+=("$arg"); done < <(persistent_exclude_filters)
terragrunt run --all ${exclude_args[@]+"${exclude_args[@]}"} --non-interactive -- apply -auto-approve

cd "$REPO_ROOT/terraform/live/$PERSISTENT_EXTRA_DIR"
terragrunt run --all --non-interactive -- apply -auto-approve
