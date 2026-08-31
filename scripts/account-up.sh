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

# -auto-approve alongside --non-interactive: the latter only covers
# terragrunt's own prompts, not terraform's native apply confirmation -
# confirmed empirically, --non-interactive alone still prompted.
#
# Always apply, per-unit, not layer-wide - never a raw AWS existence check to
# decide whether to skip. That was tried and removed: it made a genuine
# policy/trust update to an already-existing role silently do nothing, twice
# in the same debugging session (confirmed live - a pushed IAM change stayed
# unapplied because this script reported "already exists" and skipped
# `apply` entirely). `terraform apply` is already idempotent when this
# project's own state owns the resource - it plans only the real diff.
# A second PROJECT_NAME's own (empty) state hitting these same account-global
# singletons would still fail with AWS's EntityAlreadyExists - that's the
# correct outcome (an explicit `terraform import` is the fix then), not
# something to paper over with a pre-check that also hides real updates.

echo "Applying github-oidc ..."
(cd "$REPO_ROOT/terraform/live/account/github-oidc" && terragrunt apply --non-interactive -auto-approve)

echo "Applying eks-access-identity ..."
(cd "$REPO_ROOT/terraform/live/account/eks-access-identity" && terragrunt apply --non-interactive -auto-approve)

# A future third account-global unit needs its own `terragrunt apply` line
# here, matching this file's pattern.
