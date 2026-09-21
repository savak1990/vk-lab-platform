# The account layer's region, and this project's own.
#
# LAB_ACCOUNT_REGION never varies. The shared secrets KMS key, lab-role, the
# GitHub OIDC provider, the access identities and the account's own state
# bucket all live there, and deriving it from anything is exactly what
# ADR 0024 prohibits - that rule is unchanged for this layer.
#
# LAB_REGION is this project's AWS region. It keeps its name because most
# uses across scripts/ are project-scoped and mean what they always did;
# only the account layer's own calls take LAB_ACCOUNT_REGION instead.
#
# REGION is the provider's region, and is already validated against
# scripts/lib/catalog.sh before any of this is read. On aws it selects the
# AWS region; on civo and hetzner it selects that cloud's own region or
# location, and their AWS-side resources stay in the account region - which
# is why LAB_REGION below does not follow them.
#
# Deliberately not named AWS_REGION and deliberately not exported: an
# exported AWS_REGION would let the AWS CLI resolve a region ambiently and
# collide with the operator's own profile.

LAB_ACCOUNT_REGION="eu-west-1"

if [ "${PROVIDER:-aws}" = "aws" ] && [ -n "${REGION:-}" ]; then
  LAB_REGION="$REGION"
else
  LAB_REGION="$LAB_ACCOUNT_REGION"
fi

if [ "${PROVIDER:-}" = "civo" ] && [ -n "${REGION:-}" ]; then
  CIVO_REGION="$REGION"
else
  CIVO_REGION="LON1"
fi

if [ "${PROVIDER:-}" = "hetzner" ] && [ -n "${REGION:-}" ]; then
  HCLOUD_LOCATION="$REGION"
else
  HCLOUD_LOCATION="nbg1"
fi

# Not derived from REGION: every location the catalogue allows is in this
# zone, and one outside it could not attach to the private network at all.
HCLOUD_NETWORK_ZONE="eu-central"
