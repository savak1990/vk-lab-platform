#!/usr/bin/env bash
# Fails if any Bootstrap- or Persistent-lifecycle resource for this
# PROJECT_NAME still exists after `make full-down`.
#
# cluster-down.sh already sweeps the Disposable layer and already exits
# non-zero when it finds something (ADR 0026 decision 2). This covers the two
# layers below it, which nothing checked: a successful `terraform destroy` is
# not proof of a successful shutdown, and a leaked hosted zone in particular
# makes require-unique-subdomain.sh refuse every later run for this project.
#
# Everything here is a direct cloud-API existence check, never a state-file
# read: bootstrap-down.sh ends by deleting s3://<project>-tf-state, so by the
# time this runs there is no state left to inspect.
set -euo pipefail

PROVIDER="${1:-}"
case "$PROVIDER" in
  aws | civo | hetzner) ;;
  *)
    echo "usage: verify-no-leaks.sh <aws|civo|hetzner>" >&2
    exit 2
    ;;
esac
export PROVIDER

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
# shellcheck source=lib/region.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

LEAKS=0

# Spelled as if/then rather than `[ test ] && leak` throughout: a false test
# in a `&&` list returns non-zero, and as the last command in a loop body that
# aborts the whole script under set -e - a clean teardown would look like a
# crash.
leak() {
  echo "VERIFY-NO-LEAKS: LEAK - $1" >&2
  LEAKS=$((LEAKS + 1))
}

echo "VERIFY-NO-LEAKS: checking project $PROJECT_NAME on $PROVIDER."

# --- S3 -------------------------------------------------------------------
# head-bucket exits non-zero for both "absent" and "denied". lab-role holds
# s3:* on exactly these two ARNs, so a denial here would itself be the bug -
# but it would read as a pass, which is why the grant is asserted in the spec
# rather than assumed silently here.
#
# A bucket that answers is not yet a leak. Deleting a bucket is eventually
# consistent, and bootstrap-down deletes the state bucket as its very last
# act - milliseconds before this runs - so the first head-bucket can still
# succeed on a bucket that is gone. A bucket already absent fails the first
# call and waits not at all, so only a suspected leak pays this time.
bucket_gone() {
  local bucket="$1" deadline
  deadline=$(( $(date +%s) + ${LEAK_BUCKET_SETTLE_SECONDS:-60} ))
  while aws s3api head-bucket --bucket "$bucket" --region "$LAB_REGION" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    echo "VERIFY-NO-LEAKS: s3://$bucket still answers; waiting for the delete to settle."
    sleep 5
  done
  return 0
}

for bucket in "${PROJECT_NAME}-${LAB_PROVIDER_REGION}-tf-state" "${PROJECT_NAME}-${LAB_PROVIDER_REGION}-postgres-backups"; do
  if ! bucket_gone "$bucket"; then
    leak "S3 bucket s3://$bucket still exists ${LEAK_BUCKET_SETTLE_SECONDS:-60}s after teardown."
  fi
done

# --- Route 53 -------------------------------------------------------------
# The fqdn embeds the root domain and is treated as private (ADR 0023), so a
# leak is reported by zone id, never by name.
if ! ROOT_DOMAIN="$(SECRET_SCOPE=global "$REPO_ROOT/scripts/secret-decrypt.sh" root-domain)"; then
  echo "VERIFY-NO-LEAKS: ERROR - could not decrypt root-domain; cannot check for a leaked zone." >&2
  exit 1
fi
FQDN="${SUBDOMAIN}.${ROOT_DOMAIN}"
# list-hosted-zones-by-name matches by lexicographic position, not exact name -
# filter to an exact, trailing-dot-normalized match.
if ! ZONE_ID="$(aws route53 list-hosted-zones-by-name \
  --dns-name "$FQDN" --region "$LAB_REGION" \
  --query "HostedZones[?Name=='${FQDN}.'].Id" --output text)"; then
  echo "VERIFY-NO-LEAKS: ERROR - route53 list-hosted-zones-by-name failed." >&2
  exit 1
fi
if [ -n "$ZONE_ID" ] && [ "$ZONE_ID" != "None" ]; then
  leak "Route 53 hosted zone $ZONE_ID for this project's subdomain still exists."
fi

# --- SSM ------------------------------------------------------------------
# Every bootstrap and persistent unit writes at least one parameter under
# /<project>/, so this one check covers the ACM certificate, the Roles
# Anywhere trust anchor and profile, the Civo network and reserved IP, and the
# persistent secrets - without needing a List grant lab-role does not hold.
#
# One exemption: argo-down deliberately exports the serving certificate to
# /<project>/persistent/civo/tls/platform-public so the next bring-up can skip
# an ACME order. A staging one is billed waste and the caller deletes it
# before this runs; a production one is kept on purpose and is not a leak.
KEPT_TLS="/${PROJECT_NAME}/persistent/${PROVIDER}/tls/platform-public"
# describe-parameters, not get-parameters-by-path: lab-role grants the latter
# only on the layer paths a unit writes (parameter/*/bootstrap/*, /persistent/*
# and so on), while a path query is authorized against the prefix itself -
# parameter/<project>/ - which matches none of them. DescribeParameters is
# granted on "*" because AWS requires that for list-type actions, so this asks
# the same question within the permissions the role already has.
if ! PARAMS="$(aws ssm describe-parameters --region "$LAB_REGION" \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/${PROJECT_NAME}/" \
  --query 'Parameters[].Name' --output text)"; then
  echo "VERIFY-NO-LEAKS: ERROR - ssm describe-parameters failed." >&2
  exit 1
fi
for p in $PARAMS; do
  if [ "$p" = "None" ]; then
    continue
  fi
  if [ "$p" = "$KEPT_TLS" ]; then
    echo "VERIFY-NO-LEAKS: keeping $p - the deliberately retained serving certificate."
    continue
  fi
  leak "SSM parameter $p still exists."
done

# --- per-provider ---------------------------------------------------------
if [ "$PROVIDER" = "aws" ]; then
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$LAB_REGION" >/dev/null 2>&1; then
    leak "EKS cluster $CLUSTER_NAME still exists."
  fi
elif [ "$PROVIDER" = "hetzner" ]; then
  hcloud_token

  # Every unit labels what it creates with project=<name>, so one selector
  # covers both layers. Read independently of cluster-down's own sweep: this
  # has to be able to disagree with it.
  for resource in network ssh-key firewall server volume primary-ip; do
    for name in $(hcloud_list_names "$resource" || true); do
      leak "Hetzner $resource $name still exists."
    done
  done

  # The cloud controller manager labels nothing it creates, so a load balancer
  # it made is invisible to the selector above and matches only on the name.
  for name in $(hcloud_cli load-balancer list -o json 2>/dev/null \
    | jq -r '(. // [])[].name' | grep -- "^${PROJECT_NAME}-" || true); do
    leak "Hetzner load balancer $name still exists."
  done
else
  civo_token

  # civo_list_names reads .name, but civo_network is created with a `label`
  # attribute - so networks are read here directly, over both keys, rather
  # than through that helper. A helper that silently matched nothing would
  # look identical to a clean teardown.
  civo_names() {
    local raw
    raw="$(civo_cli "$1" ls -o json --region "$CIVO_REGION" 2>/dev/null || true)"
    case "$raw" in
      \[*) echo "$raw" | jq -r '.[] | (.name // .label // empty)' ;;
    esac
  }

  for name in $(civo_names kubernetes); do
    if [ "$name" = "$PROJECT_NAME" ]; then
      leak "Civo cluster $name still exists."
    fi
  done
  for name in $(civo_names network); do
    if [ "$name" = "$PROJECT_NAME" ]; then
      leak "Civo network $name still exists."
    fi
  done
  for name in $(civo_names firewall); do
    case "$name" in
      "${PROJECT_NAME}-k8s" | "${PROJECT_NAME}-lb") leak "Civo firewall $name still exists." ;;
    esac
  done
  for name in $(civo_names ip); do
    if [ "$name" = "${PROJECT_NAME}-ingress" ]; then
      leak "Civo reserved IP $name still exists."
    fi
  done
fi

# The Roles Anywhere chain is built only where a workload CA exists, which is
# every target but aws. lab-role has iam:GetRole but not iam:ListRoles, so each
# consumer role is looked up by its exact name rather than enumerated.
if [ "$PROVIDER" != "aws" ]; then
  for consumer in eso external-dns cert-manager pgbackup; do
    role="${PROJECT_NAME}-ra-${consumer}"
    if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
      leak "IAM role $role still exists."
    fi
  done
fi

if [ "$LEAKS" -eq 0 ]; then
  echo "VERIFY-NO-LEAKS: no bootstrap or persistent resources remain for $PROJECT_NAME."
  exit 0
fi

echo "VERIFY-NO-LEAKS: ERROR - $LEAKS leaked resource(s) found after full-down." >&2
echo "VERIFY-NO-LEAKS: the teardown reported success but did not finish. This bills money and," >&2
echo "VERIFY-NO-LEAKS: for a hosted zone, blocks every later run of this project. Failing so it surfaces." >&2
exit 1
