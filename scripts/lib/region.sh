# The account layer's region, and this project's own.
#
# LAB_ACCOUNT_REGION never varies. The shared secrets KMS key, lab-role, the
# GitHub OIDC provider, the access identities and the account's own state
# bucket all live there, and deriving it from anything is exactly what
# ADR 0024 prohibits - that rule is unchanged for this layer.
#
# LAB_REGION is this project's AWS region. Every AWS resource the platform
# creates lives in the account region whatever the target, so the two always
# hold the same value. Both names survive because they answer different
# questions - whose resource is this, and where does the account live - and
# because renaming either would touch ~80 call sites to change nothing.
#
# REGION is the provider's region, validated against scripts/lib/catalog.sh
# before any of this is read. It selects a Civo region or a Hetzner location
# only; on aws it is refused, so nothing here reads it.
#
# Deliberately not named AWS_REGION and deliberately not exported: an
# exported AWS_REGION would let the AWS CLI resolve a region ambiently and
# collide with the operator's own profile.

LAB_ACCOUNT_REGION="eu-west-1"
LAB_REGION="$LAB_ACCOUNT_REGION"

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

# The provider's own region, lowercased: what namespaces this project's
# Terraform state. A state bucket is an AWS resource and lives in
# LAB_REGION, but its NAME says whose state it holds - without that, two
# Civo regions would share one state and the second run would orphan the
# first's network while believing it had built cleanly.
case "${PROVIDER:-aws}" in
  civo) LAB_PROVIDER_REGION="$(printf '%s' "$CIVO_REGION" | tr '[:upper:]' '[:lower:]')" ;;
  hetzner) LAB_PROVIDER_REGION="$HCLOUD_LOCATION" ;;
  *) LAB_PROVIDER_REGION="$LAB_REGION" ;;
esac
