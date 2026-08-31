#!/usr/bin/env bash
# Wires lab-up.yml/lab-down.yml's repo variable/secret: vars.AWS_ROLE_ARN
# (personal-lab-role's own ARN) and secrets.ROOT_DOMAIN (from the already-
# encrypted secrets/$PROJECT_NAME/root-domain.enc, not typed in by hand).
# One-time, per-project, manual - deliberately not part of `make full-up`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
GITHUB_REPO="${GITHUB_REPO:-savak1990/vk-lab-platform}"

if ! role_arn=$(aws iam get-role --role-name personal-lab-role --query Role.Arn --output text 2>/dev/null); then
  echo "personal-lab-role not found. Run 'make bootstrap-up' first." >&2
  exit 1
fi

gh variable set AWS_ROLE_ARN --repo "$GITHUB_REPO" --body "$role_arn"
echo "Set $GITHUB_REPO vars.AWS_ROLE_ARN = $role_arn"

if [ -f "$REPO_ROOT/secrets/$PROJECT_NAME/root-domain.enc" ]; then
  "$REPO_ROOT/scripts/secret-decrypt.sh" root-domain | gh secret set ROOT_DOMAIN --repo "$GITHUB_REPO"
  echo "Set $GITHUB_REPO secrets.ROOT_DOMAIN"
else
  echo "secrets/$PROJECT_NAME/root-domain.enc not found - skipping secrets.ROOT_DOMAIN." >&2
  echo "Only needed for lab-up.yml's depth=full-up; set it by hand once that file exists." >&2
fi

echo "Still manual: create the ephemeral-teardown Environment (Settings > Environments) with a required reviewer - not scriptable via gh for this repo."
