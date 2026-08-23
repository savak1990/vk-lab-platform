# ADR 0013: Postgres recovery moves to CNPG VolumeSnapshot; volume moves off Terraform

## Status

Accepted

## Context

Spec 007-1 confirmed, empirically, that ADR 0009's static-PV/`pvcTemplate` recovery mechanism does not work: CNPG's pre-flight check doesn't adopt the pre-existing PGDATA on the reattached, Terraform-owned (ADR 0010) EBS volume — it quarantines it (renames aside with a timestamp suffix) and runs a fresh `initdb` on every `cluster-down`/`cluster-up` cycle. Every prior cycle's data was silently discarded.

Two replacement designs were evaluated:

- **Barman Cloud plugin + S3** (continuous WAL archiving/PITR) — rejected. It requires cert-manager for plugin↔operator mTLS, a dependency this repo has none of and would add solely for this. It also exceeds spec 007-1's actual scope (survive one teardown cycle) into general disaster recovery, which `architecture.md` §4 explicitly excludes as a non-goal.
- **CNPG native VolumeSnapshot recovery** (chosen) — confirmed via CNPG's own docs that cold (`online: false`) volume-snapshot backups need neither an object store nor a WAL archiver, only a CSI driver that supports snapshots (the existing `ebs.csi.aws.com` driver does, chart `2.53.0` / driver ~v1.53.x, confirmed to support `VolumeSnapshotClass.parameters.tagSpecification_N` since ~v1.13.0) and a `VolumeSnapshotClass`. This is core CNPG, not a plugin. It matches spec 007-1's scope exactly: one recovery point taken right before teardown, nothing more.

## Decision

**Postgres storage moves fully off Terraform.** `terraform/live/persistent/postgres-volume` and `terraform/modules/ebs-volume` are deleted. The Postgres EBS volume becomes an ordinary dynamically-provisioned PVC on a new `Delete`-reclaim `StorageClass` (`ebs-delete`) — created fresh by the EBS CSI driver every cycle, destroyed the same way. Terraform never sees it. Unlike ADR 0010's problem (a Terraform-declared `size` fighting CNPG's grow-only resize), there is no analogous problem to solve here: the snapshot that survives a teardown cycle is created by the *running cluster*, at a time and with an ID Terraform's apply-time model has no way to represent. Tracking it via a Terraform data source would recreate the exact ownership mismatch ADR 0010 solved for volumes, for no benefit.

**Lifecycle-class move, stated explicitly (CLAUDE.md requires this be justified, not left implicit):**
- The EBS **volume** moves **Persistent → Disposable**.
- The EBS **snapshot** becomes a new **Persistent**-class resource: it survives `cluster-down`, and is deleted only by `persistent-down.sh`.

**Recovery mechanism:**
- `scripts/argo-down.sh`, before the existing cascade delete, forces a CNPG `Backup` (`method: volumeSnapshot`, `online: false`) against the live cluster, waits for `Completed`, then prunes old snapshots to the newest 2. If the backup doesn't complete, `argo-down.sh` aborts loudly rather than proceeding — proceeding would destroy the only copy.
- `scripts/argo-up.sh`, before installing `root-application`, discovers the latest snapshot via `aws ec2 describe-snapshots` (tag-filtered, `--owner-ids self`, `status=completed`), prunes as a safety net, and passes the handle (or an empty string, for a genuinely fresh environment) as `postgres.recoverySnapshotHandle` into the gitops chart's Helm values.
- The `gitops` chart (`postgres/recovered-snapshot.yaml`) renders a pre-provisioned `VolumeSnapshotContent` (carrying that handle, `deletionPolicy: Retain` set explicitly — **not inherited** from the `VolumeSnapshotClass` — and a `VolumeSnapshot` bound to it) only when the handle is non-empty.
- The `Cluster` CR (`postgres/cluster.yaml`) branches its `bootstrap` stanza on the same value: `recovery.volumeSnapshots.storage` when a handle was found, `initdb` (unchanged) otherwise.
- **If a snapshot exists but recovery from it fails, the cluster stays down — there is no fallback to `initdb`.** This is intentional: a loud failure beats silently wiping a recoverable database. Do not "fix" this into a fallback later.

**Tagging:** a single static tag, `Project=<project>` + `Component=postgres`, applied by the EBS CSI driver (not CNPG, not the scripts) via `VolumeSnapshotClass.parameters.tagSpecification_1`. Static rather than interpolated from the K8s object name (`{{ .VolumeSnapshotName }}`-style) — that name changes every cycle; the tag driving discovery/pruning/deletion must not.

**Retention:** newest 2 snapshots, enforced by the scripts calling the AWS API directly — not CNPG's `.spec.backup.retentionPolicy`, which has an open, unresolved pruning bug (cloudnative-pg/cloudnative-pg#8599) as of this writing. `persistent-down.sh` deletes *all* snapshots for this tag, alongside its existing retained-volume cleanup (ADR 0008) — a full wipe is expected when tearing down the persistent tier.

**New controller dependency:** neither EKS nor the `aws-ebs-csi-driver` chart ships the `external-snapshotter` CRDs or the cluster-wide `snapshot-controller` (confirmed — the chart only carries the per-driver `csi-snapshotter` sidecar). No maintained Helm chart exists for it, so `gitops/templates/platform/aws/ebs-csi/snapshot-controller.yaml` points two Argo Applications directly at `kubernetes-csi/external-snapshotter`'s own release manifests (pinned `v8.6.0`, matching the sidecar's pinned image tag) rather than an unofficial third-party chart. The `ebs-csi-driver` Application's chart values now also set `sidecars.snapshotter.forceEnable: true` explicitly — that sidecar's default (`false`) only activates via live detection of the snapshot CRDs already being present at render time, which is fragile given those CRDs are installed by a separate Application in this same rollout.

## Consequences

- `docs/adr/0009-postgres-operator-cloudnativepg.md`'s static-PV/`pvcTemplate` decision and `docs/adr/0010-postgres-volume-terraform-owned.md`'s Terraform-owned-volume decision are both superseded by this ADR, not rewritten there — both were reasonable given what was known at the time; ADR 0009 already carries a pointer note to this effect.
- `gitops/templates/platform/aws/postgres/recovered-pv.yaml` is deleted, replaced by `recovered-snapshot.yaml`. The `pvcTemplate`/`existingVolumeHandle`/`existingVolumeAz`/`existingVolumeSize` values are gone; `postgres.recoverySnapshotHandle` replaces all three.
- `ebs-retain` (the original `Retain`-reclaim `StorageClass`, ADR 0008) is left in place, unused by Postgres going forward, rather than deleted or repurposed — it remains a valid general contract for any future component that needs the same Retain semantics, and `persistent-down.sh`'s existing retained-volume cleanup (filtered on that StorageClass's tags) still protects any future user of it.
- Fixed in passing: `ebs-retain`'s, the new `ebs-delete`'s, and `karpenter/nodepool.yaml`'s `EC2NodeClass` `Project` tags were all hardcoded `"vk-lab-platform"`, not templated through `.Values.project` — a documented known limitation (`persistent-down.sh`) that would have caused two environments with different `PROJECT_NAME` values to leak (or, worse, cross-match) each other's tagged AWS resources. All now read `Project={{ .Values.project }}`, matching the new `VolumeSnapshotClass`'s tagging scheme.
- No `architecture.md` non-goal amendment is needed — that was only required for the rejected Barman/S3 path. VolumeSnapshot recovery-on-teardown doesn't read as "enterprise disaster recovery."
- The `Cluster`/PVC/PV deletion chain on teardown depends on the same load-bearing assumption spec 006-1 relies on for Karpenter's `NodeClaim`: that Argo's wave-reversed cascade `--wait` genuinely blocks until each wave's finalizers clear, not just issues deletes in order. `cluster.yaml` already sits at sync-wave `1`, above the `ebs-csi-driver` Application's wave `-1`, mirroring that pattern. Verify empirically (`kubectl get pvc -w` while deleting `root`) alongside whatever spec 006-1's own implementation verifies for Karpenter — this is the same mechanism, one more resource chain to watch, not new work.
- Verification requires **three** full `cluster-down`/`cluster-up` cycles, not two — the third is where a wrong snapshot-handle discovery or retention-count bug tends to surface. See spec 007-1's testing section and `tests/manual/007-postgres.md`, both updated alongside this ADR.
