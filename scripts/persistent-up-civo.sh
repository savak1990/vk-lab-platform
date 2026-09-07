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
terragrunt run --all --filter "!./$PERSISTENT_EXCLUDE" --non-interactive -- apply -auto-approve

cd "$REPO_ROOT/terraform/live/$PERSISTENT_EXTRA_DIR"
terragrunt run --all --non-interactive -- apply -auto-approve
