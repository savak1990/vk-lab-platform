#!/usr/bin/env bash
# Destroys Persistent-lifecycle resources: the lab DNS zone (and its
# parent-zone NS delegation record), the ACM certificate, everything in
# Secrets Manager, and every retained EBS volume the ebs-retain
# StorageClass created (spec 005). Those volumes are Persistent-lifecycle
# data but live outside any Terraform state (no stack creates them, the
# CSI driver does) - this script is where their deletion is accounted for,
# since persistent-down is already the guarded, rarely-run path for
# permanently deleting Persistent data. Guarded: refuses while Disposable
# state exists, and verifies afterward that every unit's state is actually
# empty - `dependency`-based destroy ordering applies acm/secrets before
# route53, and a partial failure there could otherwise leave the zone (and
# its parent-zone delegation) orphaned while reporting success.
# Confirmation is terragrunt's own interactive destroy prompt below (typing
# "yes"), not a separate custom one - same approach as bootstrap-down.sh;
# the volume list is echoed before that prompt so it covers volumes too.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
REGION="${REGION:-eu-west-1}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Checks actual resource counts inside each state file, not just whether
# the key exists - a destroyed stack's (now-empty) state file is never
# deleted, so a plain existence check would refuse forever after the first
# apply. Explicitly checks each aws/jq call's exit status and `return`s
# non-zero on failure - set -e does NOT reliably abort a function invoked
# via command substitution (var=$(func)) the way it aborts a plain
# top-level statement, so an aws failure here must be caught by hand
# rather than trusted to propagate on its own (verified empirically; this
# is not the "plain statement" case bootstrap-down.sh's own comment relies on).
count_resources() {
  local prefix="$1"
  local keys
  if ! keys=$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "$prefix/" --region "$REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text); then
    echo "Failed to list s3://$STATE_BUCKET/$prefix/ - aborting rather than treating this as 'no resources'." >&2
    return 1
  fi

  local total=0
  # An empty prefix makes list-objects-v2's JMESPath filter evaluate
  # against null, which --output text renders as the literal string
  # "None" - not empty - so this must be checked explicitly.
  if [ -n "$keys" ] && [ "$keys" != "None" ]; then
    local key count
    for key in $keys; do
      if ! aws s3api get-object --bucket "$STATE_BUCKET" --key "$key" --region "$REGION" "$TMP_DIR/state.json" >/dev/null; then
        echo "Failed to read state object $key - aborting rather than treating this as 'no resources'." >&2
        return 1
      fi
      if ! count=$(jq '.resources | length' "$TMP_DIR/state.json"); then
        echo "Failed to parse state object $key - aborting rather than treating this as 'no resources'." >&2
        return 1
      fi
      total=$((total + count))
    done
  fi
  echo "$total"
}

# Note: matched by Lifecycle=persistent, not just ManagedBy=ebs-csi-driver -
# a future Delete-reclaim scratch StorageClass could set ManagedBy the same
# way, and only Lifecycle=persistent actually means "this is retained data".
# The Project tag is hardcoded "vk-lab-platform" in the StorageClass today
# (gitops/templates/platform/aws/ebs-csi/storageclass.yaml), not templated
# through PROJECT_NAME - a CI run with a different PROJECT_NAME would find
# zero volumes here and silently leak them. Known limitation; fix by
# threading PROJECT_NAME into the gitops Helm values before CI relies on this.
list_retained_volumes() {
  aws ec2 describe-volumes \
    --region "$REGION" \
    --filters \
      "Name=tag:Lifecycle,Values=persistent" \
      "Name=tag:ManagedBy,Values=ebs-csi-driver" \
      "Name=tag:Project,Values=$PROJECT_NAME" \
      "Name=status,Values=available" \
    --query "Volumes[].{Id:VolumeId,Size:Size,AZ:AvailabilityZone}" \
    --output json
}

echo "Checking for Disposable state in s3://$STATE_BUCKET ..."

if ! disposable_total=$(count_resources "disposable"); then
  exit 1
fi
if [ "$disposable_total" -gt 0 ]; then
  echo "Refusing: disposable state still has $disposable_total resource(s). Run 'make down' first."
  exit 1
fi

if ! retained_volumes=$(list_retained_volumes); then
  echo "Failed to list retained EBS volumes - aborting." >&2
  exit 1
fi
retained_count=$(echo "$retained_volumes" | jq 'length')

echo "This permanently deletes the lab.<root-domain> DNS zone (and its parent-zone NS"
echo "delegation record), its ACM certificate, and every secret in Secrets Manager."
if [ "$retained_count" -gt 0 ]; then
  echo "It will also permanently delete $retained_count retained EBS volume(s):"
  echo "$retained_volumes" | jq -r '.[] | "  \(.Id)  \(.Size)GiB  \(.AZ)"'
fi
echo "This is expected to run essentially never."

cd "$REPO_ROOT/terraform/live/persistent"

# If PROJECT_NAME/REGION/SUBDOMAIN differs from whatever this unit's
# .terragrunt-cache was last built against, terraform will refuse with
# "Backend configuration has changed" - run `make clear-cache` first in
# that case. No --non-interactive here: terragrunt's own destroy prompt
# (type "yes") is the confirmation step, not a custom one.
terragrunt run --all destroy

for unit_prefix in persistent/route53 persistent/acm persistent/secrets; do
  if ! remaining=$(count_resources "$unit_prefix"); then
    exit 1
  fi
  if [ "$remaining" -gt 0 ]; then
    echo "Refusing to report success: $unit_prefix still has $remaining resource(s) after destroy." >&2
    exit 1
  fi
done

echo "Persistent-lifecycle resources destroyed."

# Runs after Terraform destroy is verified clean, not before - a partial
# terragrunt failure above already exits, so a volume is only ever deleted
# once nothing state-tracked could still depend on it.
if [ "$retained_count" -gt 0 ]; then
  echo "$retained_volumes" | jq -r '.[].Id' | while read -r volume_id; do
    aws ec2 delete-volume --region "$REGION" --volume-id "$volume_id"
    echo "Deleted retained volume $volume_id"
  done
fi
