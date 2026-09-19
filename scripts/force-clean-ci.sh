#!/usr/bin/env bash
# Removes what a killed bring-up leaves behind, which no teardown can reach.
#
# terraform creates a resource and *then* records it in state. Those two steps
# are not atomic, so a run killed between them leaves the resource live in AWS
# and absent from state. `terraform destroy` reads state, not the account, so a
# later full-down reports success and deletes nothing - this was reproduced,
# not theorized. The orphan then blocks every later run:
#
#   - a leftover hosted zone makes require-unique-subdomain.sh refuse, because
#     the project's own state does not claim it;
#   - a leftover .tflock makes the next apply or destroy refuse to start;
#   - a leftover SSM parameter fails the next apply with ParameterAlreadyExists,
#     since aws_ssm_parameter creates without overwrite. This one is free to
#     keep, so no bill ever reveals it.
#
# This deletes by hand what terraform can no longer see. It is a recovery tool,
# never part of a normal lifecycle: everything here is something full-down
# would have removed if state had survived.
set -euo pipefail

PROVIDER="${1:-}"
case "$PROVIDER" in
  aws | civo) ;;
  *)
    echo "usage: CONFIRM_DESTROY=<project> PROJECT_NAME=<project> SUBDOMAIN=<sub> force-clean-ci.sh <aws|civo>" >&2
    exit 2
    ;;
esac
export PROVIDER

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
# shellcheck source=lib/region.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
# shellcheck source=lib/confirm-destroy.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/confirm-destroy.sh"

# This script deletes without terraform's own plan/confirm in front of it, so
# the guard every other destroy path uses applies here too.
confirm_destroy "$PROJECT_NAME"

STATE_BUCKET="${PROJECT_NAME}-tf-state"
CLEANED=0

echo "FORCE-CLEAN-CI: $PROJECT_NAME on $PROVIDER."

# --- 1. the stale lock ----------------------------------------------------
# Removed first: while it is held, the teardown this script is recovering from
# cannot run at all.
LOCK="bootstrap/route53/terraform.tfstate.tflock"
if aws s3api head-object --bucket "$STATE_BUCKET" --key "$LOCK" --region "$LAB_REGION" >/dev/null 2>&1; then
  aws s3 rm "s3://$STATE_BUCKET/$LOCK" >/dev/null
  echo "FORCE-CLEAN-CI: removed the stale state lock $LOCK."
  CLEANED=$((CLEANED + 1))
fi

# --- 2. the orphaned hosted zone ------------------------------------------
if ! ROOT_DOMAIN="$(SECRET_SCOPE=global "$REPO_ROOT/scripts/secret-decrypt.sh" root-domain)"; then
  echo "FORCE-CLEAN-CI: ERROR - could not decrypt root-domain." >&2
  exit 1
fi
FQDN="${SUBDOMAIN}.${ROOT_DOMAIN}"
ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$FQDN" --region "$LAB_REGION" \
  --query "HostedZones[?Name=='${FQDN}.'].Id" --output text)"

if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; then
  # Only an orphan qualifies. If this project's own route53 state tracks the
  # zone, terraform still owns it and full-down is the right tool - deleting it
  # here would strand that state instead of fixing anything.
  TRACKED=""
  TMP_STATE="$(mktemp)"
  trap 'rm -f "$TMP_STATE"' EXIT
  if aws s3api get-object --bucket "$STATE_BUCKET" \
    --key "bootstrap/route53/terraform.tfstate" --region "$LAB_REGION" \
    "$TMP_STATE" >/dev/null 2>&1; then
    TRACKED="$(jq -r '.resources[] | select(.mode=="managed" and .type=="aws_route53_zone") | .instances[0].attributes.zone_id // ""' "$TMP_STATE")"
  fi

  if [ -n "$TRACKED" ]; then
    echo "FORCE-CLEAN-CI: kept the zone - $PROJECT_NAME's own state tracks it. Use make full-down." >&2
    exit 1
  fi

  # A zone holding real records is in use by something. Refuse rather than
  # guess: an empty zone is the signature of a bring-up that died early.
  EXTRA="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "length(ResourceRecordSets[?Type!='NS' && Type!='SOA'])" --output text)"
  if [ "$EXTRA" != "0" ]; then
    echo "FORCE-CLEAN-CI: ERROR - the zone holds $EXTRA record(s) beyond its own NS and SOA." >&2
    echo "FORCE-CLEAN-CI: that is not an abandoned zone. Inspect it before deleting anything." >&2
    exit 1
  fi

  aws route53 delete-hosted-zone --id "$ZONE_ID" >/dev/null
  echo "FORCE-CLEAN-CI: deleted the orphaned hosted zone $ZONE_ID."
  CLEANED=$((CLEANED + 1))
fi

# --- 3. the orphaned SSM parameters ---------------------------------------
# The retained serving certificate is exempt for the same reason
# verify-no-leaks.sh exempts it: argo-down writes it on purpose so the next
# bring-up can skip an ACME order.
KEPT_TLS="/${PROJECT_NAME}/persistent/civo/tls/platform-public"
# describe-parameters rather than a path query, for the reason
# verify-no-leaks.sh records: lab-role authorizes a path query against the
# prefix parameter/<project>/, which none of its grants match.
PARAMS="$(aws ssm describe-parameters --region "$LAB_REGION" \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/${PROJECT_NAME}/" \
  --query 'Parameters[].Name' --output text)"
for p in $PARAMS; do
  if [ "$p" = "None" ] || [ "$p" = "$KEPT_TLS" ]; then
    continue
  fi
  aws ssm delete-parameter --region "$LAB_REGION" --name "$p" >/dev/null
  echo "FORCE-CLEAN-CI: deleted the orphaned parameter $p."
  CLEANED=$((CLEANED + 1))
done

if [ "$CLEANED" -eq 0 ]; then
  echo "FORCE-CLEAN-CI: nothing to clean - $PROJECT_NAME has no orphans."
else
  echo "FORCE-CLEAN-CI: removed $CLEANED orphan(s). $PROJECT_NAME can bootstrap again."
fi
