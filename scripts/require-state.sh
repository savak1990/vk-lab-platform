#!/usr/bin/env bash
# Fails fast if the State layer's bucket doesn't exist yet. Used as
# bootstrap-up's prerequisite check - kept separate from status.sh, which
# is purely informational and always exits 0.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
  echo "s3://$BUCKET does not exist. Run 'make state-up' first." >&2
  exit 1
fi
