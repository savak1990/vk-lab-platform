#!/usr/bin/env bash
# Fails fast if SUBDOMAIN.ROOT_DOMAIN is already a live Route53 hosted
# zone owned by a DIFFERENT project. Without this, two PROJECT_NAME
# environments sharing the default SUBDOMAIN=lab would both create a zone
# named lab.<root-domain>, and the second apply's NS delegation record in
# the parent zone silently overwrites the first's - Route53 allows
# multiple same-named hosted zones, but the parent zone can hold only one
# NS record set per name, so the second project's bootstrap-up would
# quietly break the first project's DNS.
#
# Ownership is decided by state, not by tagging the zone: does the
# *current* PROJECT_NAME's own bootstrap/route53 Terraform state already
# track an aws_route53_zone resource? If a same-named zone exists in
# Route53 but this project's state doesn't know about it, it belongs to
# someone else (or was created out-of-band) - refuse. Same
# state-inspection technique persistent-down.sh already uses to verify
# destroy completed, applied here before creation instead.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
SUBDOMAIN="${SUBDOMAIN:-lab}"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
STATE_KEY="bootstrap/route53/terraform.tfstate"

# lab-role already holds kms:* on alias/lab-secrets (for the SSM
# SecureString parameters), so CI decrypts root-domain.enc directly too -
# no separate ROOT_DOMAIN GitHub secret needed.
ROOT_DOMAIN="$("$REPO_ROOT/scripts/secret-decrypt.sh" root-domain)"
FQDN="${SUBDOMAIN}.${ROOT_DOMAIN}"

# list-hosted-zones-by-name matches by prefix/lexicographic position, not
# exact name - filter down to an exact, trailing-dot-normalized match.
EXISTING_ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$FQDN" --region "$PROJECT_REGION" \
  --query "HostedZones[?Name=='${FQDN}.'].Id" --output text)"

if [ -z "$EXISTING_ZONE_ID" ] || [ "$EXISTING_ZONE_ID" = "None" ]; then
  echo "REQUIRE-UNIQUE-SUBDOMAIN: no existing zone for $FQDN - clear to proceed."
  exit 0
fi

TMP_STATE="$(mktemp)"
trap 'rm -f "$TMP_STATE"' EXIT

if ! aws s3api get-object --bucket "$STATE_BUCKET" --key "$STATE_KEY" --region "$PROJECT_REGION" "$TMP_STATE" >/dev/null 2>&1; then
  echo "REQUIRE-UNIQUE-SUBDOMAIN: refusing - a Route53 zone for $FQDN already exists ($EXISTING_ZONE_ID)," >&2
  echo "but PROJECT_NAME=$PROJECT_NAME has no bootstrap/route53 state - it doesn't own this zone." >&2
  echo "Pick a different SUBDOMAIN for this project, e.g.: SUBDOMAIN=$PROJECT_NAME make bootstrap-up" >&2
  exit 1
fi

# mode=="managed" matters: the module also holds a data "aws_route53_zone"
# lookup of the PARENT zone, and without this filter both zone ids come
# back and the comparison below can never match.
TRACKED_ZONE_ID="$(jq -r '.resources[] | select(.mode=="managed" and .type=="aws_route53_zone") | .instances[0].attributes.zone_id // ""' "$TMP_STATE")"
if [ "$TRACKED_ZONE_ID" != "${EXISTING_ZONE_ID#/hostedzone/}" ]; then
  echo "REQUIRE-UNIQUE-SUBDOMAIN: refusing - a Route53 zone for $FQDN already exists ($EXISTING_ZONE_ID)," >&2
  echo "but it doesn't match what PROJECT_NAME=$PROJECT_NAME's own state tracks (${TRACKED_ZONE_ID:-none})." >&2
  echo "Pick a different SUBDOMAIN for this project, e.g.: SUBDOMAIN=$PROJECT_NAME make bootstrap-up" >&2
  exit 1
fi

echo "REQUIRE-UNIQUE-SUBDOMAIN: $FQDN is already owned by PROJECT_NAME=$PROJECT_NAME's own state - clear to proceed."
