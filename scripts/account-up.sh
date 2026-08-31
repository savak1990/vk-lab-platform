#!/usr/bin/env bash
# Creates account-global resources (the GitHub OIDC provider,
# eks-access-identity). Run once per AWS account from a workstation, with the
# primary PROJECT_NAME - never from CI, and never with a per-PR PROJECT_NAME.
# Deliberately not part of `make up` or `make full-up`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Units here inherit the S3 backend, so a missing state bucket surfaces as an
# opaque backend-init error without this.
"$REPO_ROOT/scripts/require-state.sh"

# Per-unit, not layer-wide: a second project's own Terraform state has never
# seen these account-global resources, so a blanket `run --all apply` after
# the first project already created them would try to recreate whichever one
# already exists and get AWS's EntityAlreadyExists - checked and skipped
# individually instead, so a genuinely new unit still gets applied even after
# an older one already exists.

echo "Checking github-oidc ..."
GITHUB_ISSUER="token.actions.githubusercontent.com"
# An empty JMESPath result renders as the literal string "None" under
# --output text, not as an empty string.
existing_provider=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '$GITHUB_ISSUER')].Arn" \
  --output text)

if [ -n "$existing_provider" ] && [ "$existing_provider" != "None" ]; then
  echo "GitHub OIDC provider already exists: $existing_provider - nothing to create."
else
  (cd "$REPO_ROOT/terraform/live/account/github-oidc" && terragrunt apply --non-interactive)
fi

echo "Checking eks-access-identity ..."
if aws iam get-role --role-name eks-access-identity >/dev/null 2>&1; then
  echo "eks-access-identity already exists - nothing to create."
else
  (cd "$REPO_ROOT/terraform/live/account/eks-access-identity" && terragrunt apply --non-interactive)
fi

# A future third account-global unit needs its own check block here, matching
# this file's pattern - there's no shared existence check across resource types.
