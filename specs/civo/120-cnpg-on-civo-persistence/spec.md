---
id: "CIVO-120"
title: "CloudNativePG on Civo with persistence through object-store backups"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "Data-safety path across cluster destruction; backup and restore must be reasoned through with failure modes"
effort_estimate: "One to two sessions (6–10 h) including two full down/up cycles"
estimate_confidence: "medium"
depends_on: ["CIVO-050", "CIVO-100", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-120 — CNPG on Civo with persistence

## 1. Outcome and rationale

A single-instance CNPG cluster runs on Civo storage with the app password
from ESO. Rows written before `make down` are present after `make up`.
Persistence comes from barman-cloud backups in the Civo Object Store
(CIVO-180), not from volume snapshots. The Civo CSI driver
(`csi.civo.com`) has no snapshot or clone capability, so the snapshot
path used on AWS (ADR 0013) cannot work on Civo.

## 2. Scope and non-goals

In scope:
- CNPG `Cluster` values for Civo.
- The barman-cloud plugin `ObjectStore` reference, WAL archiving, and a daily `ScheduledBackup`.
- The `argo-down` Civo branch: an on-demand `Backup` that must complete before teardown.
- The `argo-up` Civo branch: bootstrap by `recovery` from the object store when a backup exists, else `initdb`.
- One restore drill into a scratch namespace.

Not in scope:
- Object store provisioning and credential delivery (CIVO-180).
- Replicas. `instances: 1` is explicit. A second instance doubles volume and RAM cost and gives no protection across cluster deletion.
- Retained-volume rebinding. The spike may test it as an experiment. It is undocumented in CNPG and is not a supported path.

## 3. Current state / evidence

- `gitops/templates/platform/aws/postgres/cluster.yaml` sets `instances: 1`, `storage.size: {{ .Values.postgres.storageSize }}` (20Gi), `storageClass: ebs-delete`, and `nodeSelector workload-type: on-demand`. It has a dual bootstrap: `recovery` from `VolumeSnapshot lab-postgres-recovered` when a handle is set, else `initdb`. It sets `backup.volumeSnapshot.className: ebs-postgres-snapshot`.
- `recovered-snapshot.yaml` holds a `VolumeSnapshotContent` with `driver ebs.csi.aws.com`, `deletionPolicy Retain`, and a `snapshotHandle` from values. It uses client-side apply.
- `argo-down.sh:54-113` creates a CNPG `Backup` (volumeSnapshot) and prunes. `argo-up.sh:167-197` discovers the newest handle.
- The Civo `civo-volume` class is RWO and WaitForFirstConsumer, with Delete reclaim. The volumes survive cluster deletion (research.md).

## 4. Design and contracts

- Storage: `storageClass: civo-volume`, 20 Gi, reclaim `Delete`. The volume is disposable. The data of record lives in the object store.
- No `nodeSelector` on Civo. `priorityClassName: postgres-critical`, requests 250m/256Mi, `wal_level` logical.
- `spec.enablePDB: false` on Civo (values-driven). CNPG creates a PDB even for one instance, and that PDB blocks the cluster autoscaler from removing the node (CIVO-170).
- Backups: the barman-cloud plugin (installed with the CNPG operator in CIVO-180) with `plugins[0].name: barman-cloud.cloudnative-pg.io` and `parameters.barmanObjectName: civo-object-store`. WAL archiving on. `ScheduledBackup` daily at 03:00 UTC, `method: plugin`. Retention 14 days, set on the `ObjectStore`.
- `argo-down` Civo branch: create `Backup lab-postgres-teardown-<epoch>` with `method: plugin`, poll `.status.phase` until `completed`, timeout 300 s. On `failed` or timeout the script exits non-zero and leaves the cluster running (fail closed), unless `CI_TEARDOWN_ALLOW_DATA_LOSS=1` is set (CIVO-140).
- `argo-up` Civo branch: query the object store for the newest completed backup (barman `list-backups` through a short `Job`, or the plugin's status on a previous run recorded in SSM `/${project}/persistent/civo/postgres/last_backup_id`). When one exists, set `postgres.recoverySource: object-store`; the `Cluster` template renders `bootstrap.recovery.source: civo-object-store` with `externalClusters[0].plugin.parameters.barmanObjectName`. When none exists, render `initdb`.
- Recovery bootstrap uses the same `ObjectStore`, so the restored cluster continues to archive WAL to the same path with a new timeline. Barman keeps the old timeline for point-in-time recovery inside the retention window.
- Values: `postgres.backup.enabled` (aws false in M1, civo true), `postgres.recoverySource` (`snapshot` on aws, `object-store` on civo, `none`).

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven); `civo/postgres/*.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh` (`civo_recovery_handle`, `civo_backup`); `scripts/lib/persistent-civo-artifacts.sh` *(new, mirrors `persistent-ebs-artifacts.sh`)*; `scripts/persistent-down.sh` (civo artifacts cleanup).

## 6. Implementation steps

1. Confirm CIVO-180 delivered the `ObjectStore` CR and the `cnpg-backup-s3` Secret.
2. Template the `Cluster`; run `make gitops-check`. The AWS golden diff must be empty.
3. `PROVIDER=civo make up`. Write test rows through the e2e Postgres test or `psql`.
4. Confirm the first scheduled backup and WAL archiving complete (`kubectl get backup`, object store listing).
5. `make down`. Confirm the teardown `Backup` completed, the cluster is gone, and the object store holds the backup.
6. `make up`. Confirm the rows are present and `argo-up` selected the newest backup.
7. Repeat steps 5 and 6 once.
8. Failure paths: a failed teardown `Backup` exits non-zero and leaves the cluster (fail closed); a bogus recovery source fails visibly with no silent `initdb`.
9. Restore drill: bootstrap a second `Cluster` from the object store in namespace `cnpg-restore-test`, compare row counts, delete it.
10. `persistent-down` Civo branch lists the object store contents and deletes the bucket only with confirmation.

## 7. Dependencies and blockers

CIVO-050 (layout), CIVO-100 (app password Secret through ESO), CIVO-180 (object store, credentials, plugin). CIVO-020 no longer gates this spec: the CSI capability list settles the snapshot question without a cluster.

## 8. Acceptance criteria

- Rows survive two down/up cycles.
- Teardown `Backup` completes within 300 s; retention keeps 14 days; storage cost recorded.
- Fail-closed behaviors verified.
- Restore drill succeeds with a matching row count.
- `cluster-down` never touches the object store; `persistent-down` deletes it only with confirmation.
- AWS golden diff empty; one AWS down/up cycle still restores from the EBS snapshot after the merge.

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: two civo cycles (~0.5 USD) and one AWS cycle (existing cost).

## 10. AWS regression protection

The Cluster template defaults equal the AWS file. The snapshot handling for aws is untouched. An AWS down/up run is recorded.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: revert the change. The retained artifacts stay until `persistent-down`.

## 12. Risks and unresolved questions

- The barman-cloud plugin version must match the CNPG operator 0.29.0 chart; confirm at implementation.
- Backup duration for 20 Gi over the Civo network sets the `argo-down` timeout; measure once and adjust.
- Static-PV rebinding of a retained Civo volume is an optional spike experiment only. Do not build on it.

## 13. Definition of done

- [ ] Mechanism chosen and documented
- [ ] Two cycles with data evidence; failure paths; AWS cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.

- 2026-09-06 — kubernetes-architect review: `csi.civo.com` advertises no `CREATE_DELETE_SNAPSHOT` or `CLONE_VOLUME` capability (https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go). Snapshot and PVC-datasource recovery dropped; redesigned around object-store backups; blocker removed; status READY with new dependency CIVO-180.

