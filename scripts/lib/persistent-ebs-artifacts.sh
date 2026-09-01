# Used by persistent-down.sh, which deletes every retained EBS volume and
# Postgres EBS snapshot for the project: this data is Persistent-lifecycle
# but lives outside any Terraform state (the EBS CSI driver creates it, not
# Terraform), so no terraform.tfstate resource count can ever reveal its
# existence - persistent-down.sh is the one place that knows to look.
# bootstrap-down.sh deliberately does not duplicate this check: it relies
# on persistent-down.sh (which full-down always runs first) having already
# deleted these before bootstrap-down ever runs. Extracted here so the
# Lifecycle/ManagedBy/Project/Component tag filters - load-bearing - have
# exactly one definition even though only one caller currently uses them.
#
# Not sourced standalone - the caller sets PROJECT_NAME/REGION first.

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

list_postgres_snapshots() {
  aws ec2 describe-snapshots \
    --region "$REGION" \
    --owner-ids self \
    --filters "Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres" \
    --query "Snapshots[].{Id:SnapshotId,StartTime:StartTime}" \
    --output json
}
