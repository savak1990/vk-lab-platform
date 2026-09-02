# Resolves ACCOUNT_MAIN_REGION, preferring the value already recorded in
# SSM over the env var - a forgotten re-export must not silently pick the
# wrong region. Distinguishes "not written yet" (expected before the first
# account-up - fall back to the env var) from any other AWS error (auth,
# throttling - abort loudly, since a silent wrong region is worse than a
# loud failure).
#
# PROJECT_REGION is deliberately NOT resolved this way: the parameter that
# would record it lives in PROJECT_REGION itself, so discovering it via SSM
# is circular (querying the wrong region just returns ParameterNotFound,
# indistinguishable from "not written yet" - silently confirming a wrong
# guess instead of catching it). PROJECT_REGION stays a plain env-var
# default; a wrong guess there already fails loudly elsewhere in the same
# script run (state bucket lookup, EKS describe, ...), so no separate
# persistence is needed - see docs/adr/0023.
#
# Not sourced standalone - callers using PROJECT_NAME still set it
# themselves; this file doesn't need it.

ACCOUNT_MAIN_REGION="${ACCOUNT_MAIN_REGION:-eu-west-1}"
if ! recorded_main_region="$(aws ssm get-parameter --name /account/main_account_region \
    --region "$ACCOUNT_MAIN_REGION" --query 'Parameter.Value' --output text 2>&1)"; then
  if [[ "$recorded_main_region" != *ParameterNotFound* ]]; then
    echo "REGION: failed to read /account/main_account_region: $recorded_main_region" >&2
    exit 1
  fi
  recorded_main_region=""
fi
[ -n "$recorded_main_region" ] && ACCOUNT_MAIN_REGION="$recorded_main_region"

PROJECT_REGION="${PROJECT_REGION:-eu-west-1}"
