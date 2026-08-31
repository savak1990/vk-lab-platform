#!/usr/bin/env bash
# Destroys Persistent-lifecycle resources: the lab DNS zone (and its
# parent-zone NS delegation record), the ACM certificate, everything in
# Secrets Manager, every retained EBS volume the ebs-retain StorageClass
# created (spec 005), and every retained Postgres EBS snapshot (ADR 0013).
# Those volumes/snapshots are Persistent-lifecycle data but live outside
# any Terraform state (no stack creates them, the CSI driver does) - this
# script is where their deletion is accounted for, since persistent-down
# is already the guarded, rarely-run path for permanently deleting
# Persistent data. Guarded: refuses while Disposable state exists, and
# verifies afterward that every unit's state is actually empty -
# `dependency`-based destroy ordering applies acm/secrets before route53,
# and a partial failure there could otherwise leave the zone (and its
# parent-zone delegation) orphaned while reporting success.
# Confirmation is terragrunt's own interactive destroy prompt below (typing
# "yes") on a workstation; a non-interactive run (no TTY, e.g. lab-down.yml's
# ungated down-through-persistent depth) skips straight to --non-interactive,
# since dispatching that workflow run is itself the confirmation step. The
# volume/snapshot lists are echoed before the prompt either way.
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
# The Project tag is templated through .Values.project in the StorageClass
# (gitops/templates/platform/aws/ebs-csi/storageclass.yaml, fixed
# alongside ADR 0013's snapshot tagging), so two environments with
# different PROJECT_NAME values never match each other's volumes here.
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

# Postgres's EBS volume itself is Disposable now (ADR 0013) - the
# Persistent-lifecycle artifact is the retained VolumeSnapshot instead,
# tagged by the VolumeSnapshotClass at snapshot-creation time (the EBS CSI
# driver sets this tag, not Terraform, so it's identified by AWS tag here
# rather than any Terraform state). A full wipe of the persistent tier is
# expected to delete all of them, not just prune to N.
list_postgres_snapshots() {
  aws ec2 describe-snapshots \
    --region "$REGION" \
    --owner-ids self \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres" \
    --query "Snapshots[].{Id:SnapshotId,StartTime:StartTime}" \
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

if ! postgres_snapshots=$(list_postgres_snapshots); then
  echo "Failed to list Postgres EBS snapshots - aborting." >&2
  exit 1
fi
postgres_snapshot_count=$(echo "$postgres_snapshots" | jq 'length')
if [ "$postgres_snapshot_count" -gt 0 ]; then
  echo "It will also permanently delete $postgres_snapshot_count Postgres EBS snapshot(s):"
  echo "$postgres_snapshots" | jq -r '.[] | "  \(.Id)  \(.StartTime)"'
fi
echo "This is expected to run essentially never."

cd "$REPO_ROOT/terraform/live/persistent"

# If PROJECT_NAME/REGION/SUBDOMAIN differs from whatever this unit's
# .terragrunt-cache was last built against, terraform will refuse with
# "Backend configuration has changed" - run `make clear-cache` first in
# that case. Unlike bootstrap-down.sh/state-down.sh, this isn't gated by
# the ephemeral allow-list - lab-down.yml's down-through-persistent depth
# runs ungated, for every registered combination, so dispatching that
# workflow run is itself the confirmation step; a workstation run still
# gets terragrunt's own interactive "yes" prompt via the TTY check below.
# -auto-approve is what actually skips it - --non-interactive alone doesn't
# (confirmed empirically).
if [ -t 0 ]; then
  terragrunt run --all destroy
else
  terragrunt run --all destroy --non-interactive -auto-approve
fi

for unit_prefix in persistent/vpc persistent/route53 persistent/acm persistent/secrets; do
  if ! remaining=$(count_resources "$unit_prefix"); then
    exit 1
  fi
  if [ "$remaining" -gt 0 ]; then
    echo "Refusing to report success: $unit_prefix still has $remaining resource(s) after destroy." >&2
    exit 1
  fi
done

# Runs after Terraform destroy is verified clean, not before - a partial
# terragrunt failure above already exits, so a volume is only ever deleted
# once nothing state-tracked could still depend on it. Re-lists rather than
# reusing $retained_volumes, since a volume could become available only
# during/after the Terraform destroy above and would otherwise be skipped.
if ! retained_volumes=$(list_retained_volumes); then
  echo "Failed to list retained EBS volumes before deletion - aborting." >&2
  exit 1
fi

failed_volumes=()
# Process substitution, not a pipe - `while read` on a pipeline runs in a
# subshell on bash 3.2 (macOS default), so appends to failed_volumes inside
# the loop wouldn't be visible after it. `mapfile` would dodge this too but
# is bash-4+ only; no other script here assumes a non-default bash.
while read -r volume_id; do
  [ -z "$volume_id" ] && continue
  if aws ec2 delete-volume --region "$REGION" --volume-id "$volume_id"; then
    echo "Deleted retained volume $volume_id"
  else
    echo "Failed to delete retained volume $volume_id" >&2
    failed_volumes+=("$volume_id")
  fi
done < <(echo "$retained_volumes" | jq -r '.[].Id')

if [ "${#failed_volumes[@]}" -gt 0 ]; then
  echo "Refusing to report success: failed to delete ${#failed_volumes[@]} retained volume(s): ${failed_volumes[*]}" >&2
  exit 1
fi

if ! remaining_volumes=$(list_retained_volumes); then
  echo "Failed to verify retained volumes were deleted - aborting." >&2
  exit 1
fi
remaining_volume_count=$(echo "$remaining_volumes" | jq 'length')
if [ "$remaining_volume_count" -gt 0 ]; then
  echo "Refusing to report success: $remaining_volume_count retained volume(s) still exist after deletion." >&2
  exit 1
fi

# Same re-list-before-delete reasoning as the volume loop above: a
# snapshot could complete only during/after the Terraform destroy and
# would otherwise be skipped.
if ! postgres_snapshots=$(list_postgres_snapshots); then
  echo "Failed to list Postgres EBS snapshots before deletion - aborting." >&2
  exit 1
fi

failed_snapshots=()
while read -r snapshot_id; do
  [ -z "$snapshot_id" ] && continue
  if aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snapshot_id"; then
    echo "Deleted Postgres snapshot $snapshot_id"
  else
    echo "Failed to delete Postgres snapshot $snapshot_id" >&2
    failed_snapshots+=("$snapshot_id")
  fi
done < <(echo "$postgres_snapshots" | jq -r '.[].Id')

if [ "${#failed_snapshots[@]}" -gt 0 ]; then
  echo "Refusing to report success: failed to delete ${#failed_snapshots[@]} Postgres snapshot(s): ${failed_snapshots[*]}" >&2
  exit 1
fi

if ! remaining_snapshots=$(list_postgres_snapshots); then
  echo "Failed to verify Postgres snapshots were deleted - aborting." >&2
  exit 1
fi
remaining_snapshot_count=$(echo "$remaining_snapshots" | jq 'length')
if [ "$remaining_snapshot_count" -gt 0 ]; then
  echo "Refusing to report success: $remaining_snapshot_count Postgres snapshot(s) still exist after deletion." >&2
  exit 1
fi

echo "Persistent-lifecycle resources destroyed."
