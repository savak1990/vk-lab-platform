#!/usr/bin/env bash
# Creates Bootstrap-lifecycle resources for this PROJECT_NAME: its own
# dedicated state bucket, then the lab DNS zone/delegation + ACM cert
# (route53 + acm - moved here from Persistent; the account-global shared
# lab-role/kms/github-oidc/eks-access-identity live in account-up instead,
# not here).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This project's own state bucket - idempotent, safe to re-run every time
# (see scripts/state-up.sh).
"$REPO_ROOT/scripts/state-up.sh"

# root-domain.enc must exist before route53's terraform apply decrypts it
# via aws_kms_secrets. generate-secrets.sh is idempotent and also produces
# the two Persistent-lifecycle passwords early (harmless - persistent-up's
# own call to it later is a no-op for anything already generated).
"$REPO_ROOT/scripts/generate-secrets.sh"
"$REPO_ROOT/scripts/require-persistent-secrets.sh"
"$REPO_ROOT/scripts/require-unique-subdomain.sh"

cd "$REPO_ROOT/terraform/live/bootstrap"
terragrunt run --all --non-interactive -- apply -auto-approve
