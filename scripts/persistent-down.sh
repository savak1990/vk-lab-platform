#!/usr/bin/env bash
# Destroys Persistent-lifecycle resources: the VPC, everything in Secrets
# Manager, every retained EBS volume the ebs-retain StorageClass created
# (spec 005), and every retained Postgres EBS snapshot (ADR 0013). The lab
# DNS zone/delegation and ACM cert are Bootstrap-lifecycle now (see
# bootstrap-down.sh) - not this script's job. The volumes/snapshots are
# Persistent-lifecycle data but live outside any Terraform state (no stack
# creates them, the CSI driver does) - this script is where their deletion
# is accounted for, since persistent-down is already the guarded,
# rarely-run path for permanently deleting Persistent data. Guarded:
# requires CONFIRM_DESTROY to match PROJECT_NAME exactly (same as
# bootstrap-down.sh/account-down.sh), refuses while Disposable state
# exists, and verifies afterward that every unit's state is actually
# empty. terragrunt's own interactive "yes" prompt is skipped (--non-
# interactive -auto-approve) since CONFIRM_DESTROY was already checked
# above - same as bootstrap-down.sh. The volume/snapshot lists are still
# echoed before destroying, either way.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/persistent-ebs-artifacts.sh"
source "$REPO_ROOT/scripts/lib/confirm-destroy.sh"

PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
STATE_BUCKET="${PROJECT_NAME}-tf-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

confirm_destroy "$PROJECT_NAME"

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
  if ! keys=$(aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "$prefix/" --region "$PROJECT_REGION" \
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
      if ! aws s3api get-object --bucket "$STATE_BUCKET" --key "$key" --region "$PROJECT_REGION" "$TMP_DIR/state.json" >/dev/null; then
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

echo "Checking for Disposable state in s3://$STATE_BUCKET ..."

if ! disposable_total=$(count_resources "cluster"); then
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

echo "This permanently deletes the VPC and every secret in Secrets Manager."
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

# If PROJECT_NAME/PROJECT_REGION/SUBDOMAIN differs from whatever this unit's
# .terragrunt-cache was last built against, terraform will refuse with
# "Backend configuration has changed" - run `make clear-cache` first in
# that case. CONFIRM_DESTROY was already checked above, so terragrunt's own
# interactive "yes" prompt would be redundant - skipped the same way
# bootstrap-down.sh skips it. -auto-approve is what actually skips it -
# --non-interactive alone doesn't (confirmed empirically).
terragrunt run --all --non-interactive -- destroy -auto-approve

for unit_prefix in persistent/vpc persistent/secrets; do
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
  if aws ec2 delete-volume --region "$PROJECT_REGION" --volume-id "$volume_id"; then
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
  if aws ec2 delete-snapshot --region "$PROJECT_REGION" --snapshot-id "$snapshot_id"; then
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
