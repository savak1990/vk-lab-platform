#!/usr/bin/env bash
# Creates account-global resources (currently the GitHub OIDC provider). Run
# once per AWS account from a workstation, with the primary PROJECT_NAME -
# never from CI, and never with a per-PR PROJECT_NAME. Deliberately not part
# of `make up` or `make full-up`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Units here inherit the S3 backend, so a missing state bucket surfaces as an
# opaque backend-init error without this.
"$REPO_ROOT/scripts/require-state.sh"

GITHUB_ISSUER="token.actions.githubusercontent.com"

# ponytail: issuer-specific check inside a layer-level script, fine while
# github-oidc is the layer's only unit; move to a per-unit precondition if it grows.
# An empty JMESPath result renders as the literal string "None" under
# --output text, not as an empty string.
existing=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, '$GITHUB_ISSUER')].Arn" \
  --output text)

if [ -n "$existing" ] && [ "$existing" != "None" ]; then
  # ponytail: exits before applying the whole layer, which is only correct while
  # github-oidc is its only unit; check per-unit once a second one lands.
  echo "GitHub OIDC provider already exists: $existing"
  echo "It is account-global - one per AWS account, shared by every project and"
  echo "PR environment - so there is nothing to create. Nothing was changed."
  exit 0
fi

cd "$REPO_ROOT/terraform/live/account"
terragrunt run --all apply --non-interactive
