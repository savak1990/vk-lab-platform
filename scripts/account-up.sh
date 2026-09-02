#!/usr/bin/env bash
# Creates account-global resources (the shared secrets KMS key, the shared
# lab-role every project's GitHub Actions run assumes, the GitHub OIDC
# provider, eks-access-identity, eks-test-identity), then wires lab.yml's repo variable/secret:
# vars.AWS_ROLE_ARN (lab-role's own ARN - set once, ever, not per-project)
# and secrets.ROOT_DOMAIN (decrypted locally, never something a CI role
# does at runtime). Run once per AWS account from a workstation - never
# from CI. Deliberately not part of `make up` or `make full-up`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
GITHUB_REPO="${GITHUB_REPO:-savak1990/vk-lab-platform}"

# This layer's own dedicated state bucket - never a project's, so no
# project's bootstrap-down can ever orphan these units' Terraform state.
"$REPO_ROOT/scripts/account-state-up.sh"

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
#
# kms and eks-access-identity both before lab-role: lab-role's
# data "aws_kms_alias" and data "aws_iam_role" (looked up by fixed name,
# "eks-access-identity") both resolve at plan time - a hard failure on a
# brand-new account if either doesn't exist yet. eks-access-identity itself
# has no such dependency on lab-role - it only interpolates lab-role's ARN
# as a string in its trust condition, not a data lookup - so this ordering
# is one-directional.

echo "Applying kms ..."
(cd "$REPO_ROOT/terraform/live/account/kms" && terragrunt apply --non-interactive -auto-approve)

echo "Applying github-oidc ..."
(cd "$REPO_ROOT/terraform/live/account/github-oidc" && terragrunt apply --non-interactive -auto-approve)

echo "Applying eks-access-identity ..."
(cd "$REPO_ROOT/terraform/live/account/eks-access-identity" && terragrunt apply --non-interactive -auto-approve)

echo "Applying eks-test-identity ..."
(cd "$REPO_ROOT/terraform/live/account/eks-test-identity" && terragrunt apply --non-interactive -auto-approve)

echo "Applying lab-role ..."
(cd "$REPO_ROOT/terraform/live/account/lab-role" && terragrunt apply --non-interactive -auto-approve)

# root-domain after lab-role (needs its new SSM write permissions) and kms
# (decrypts root-domain.enc). Validates the root domain is actually a
# reachable Route53 hosted zone before recording it - fails fast here
# instead of much later inside a project's own bootstrap/route53 apply.
# See docs/adr/0023.
echo "Applying root-domain ..."
(cd "$REPO_ROOT/terraform/live/account/root-domain" && terragrunt apply --non-interactive -auto-approve)

# --- absorbed from the now-deleted scripts/github-vars-up.sh ---

role_arn=$(aws iam get-role --role-name lab-role --query Role.Arn --output text)
gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPO" --body "$role_arn"
echo "Set $GITHUB_REPO vars.AWS_ROLE_ARN = $role_arn"

# ROOT_DOMAIN is the same value for every project (it's your one domain, not
# a per-project setting) - a repo-level secret, set once here, never per
# project. Decrypted with the operator's own credentials, not a CI role's -
# granting a GitHub Actions role KMS decrypt just to learn a non-secret
# hostname was deliberately rejected.
if [ -f "$REPO_ROOT/secrets/$PROJECT_NAME/root-domain.enc" ]; then
  "$REPO_ROOT/scripts/secret-decrypt.sh" root-domain | gh secret set ROOT_DOMAIN --repo "$GITHUB_REPO"
  echo "Set $GITHUB_REPO secrets.ROOT_DOMAIN"
else
  echo "secrets/$PROJECT_NAME/root-domain.enc not found - skipping secrets.ROOT_DOMAIN." >&2
  echo "Re-run account-up after 'make bootstrap-up' has generated it." >&2
fi

echo "Still manual: create the ephemeral-teardown Environment (Settings > Environments) with a required reviewer - not scriptable via gh for this repo."
