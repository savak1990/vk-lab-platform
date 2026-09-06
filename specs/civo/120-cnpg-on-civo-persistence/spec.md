---
id: "CIVO-120"
title: "CloudNativePG on Civo with data surviving make down / make up"
status: "BLOCKED"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "Data-safety path across cluster destruction; the mechanism depends on spike results and must be reasoned through with failure modes"
effort_estimate: "One to two sessions (6–10 h) including two full down/up cycles"
estimate_confidence: "low"
depends_on: ["CIVO-020", "CIVO-050", "CIVO-100"]
blocked_by: ["CIVO-020"]
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-120 — CNPG on Civo with persistence

## 1. Outcome and rationale

A single-instance CNPG cluster runs on Civo storage. It uses the app
password from ESO. Rows written before `make down` are present after
`make up`. Persistence on Civo must be proven against real account
resources. Do not assume it from a surviving PVC.

## 2. Scope and non-goals

In scope: the CNPG `Cluster` values for civo, the persistence mechanism
chosen by CIVO-020, the `argo-up`/`argo-down` civo persistence functions,
and the recovery template. Not in scope: backups to object storage
(CIVO-180) and replicas. Replicas are explicitly `instances: 1`. A second
instance doubles the volume and the RAM. It gives no protection across
cluster deletion.

## 3. Current state / evidence

- `gitops/templates/platform/aws/postgres/cluster.yaml` sets `instances: 1`, `storage.size: {{ .Values.postgres.storageSize }}` (20Gi), `storageClass: ebs-delete`, and `nodeSelector workload-type: on-demand`. It has a dual bootstrap: `recovery` from `VolumeSnapshot lab-postgres-recovered` when a handle is set, else `initdb`. It sets `backup.volumeSnapshot.className: ebs-postgres-snapshot`.
- `recovered-snapshot.yaml` holds a `VolumeSnapshotContent` with `driver ebs.csi.aws.com`, `deletionPolicy Retain`, and a `snapshotHandle` from values. It uses client-side apply.
- `argo-down.sh:54-113` creates a CNPG `Backup` (volumeSnapshot) and prunes. `argo-up.sh:167-197` discovers the newest handle.
- The Civo `civo-volume` class is RWO and WaitForFirstConsumer, with Delete reclaim. The volumes survive cluster deletion (research.md).

## 4. Design and contracts

The mechanism depends on the CIVO-020 result:

- **(a) VolumeSnapshot** (preferred): `civo/postgres/volumesnapshotclass.yaml` (`driver csi.civo.com`, `deletionPolicy Retain`). The `Cluster` on civo uses `storageClass: civo-volume`, no nodeSelector, and `backup.volumeSnapshot.className: civo-postgres-snapshot`. `recovered-snapshot.yaml` is templated by `.Values.storage.snapshotDriver`. The `argo-down` civo branch runs the same Backup. It prunes via the Civo API/CLI and keeps the newest 2. `argo-up` discovers the newest handle via the Civo API.
- **(b) Retained volume**: the StorageClass `civo-retain` (`reclaimPolicy Retain`). `argo-down` records the volume ID to SSM `/${project}/persistent/civo/postgres/volume_id`. `argo-up` renders a static `PV` bound by `volumeHandle` and a pre-bound PVC name. CNPG's `Cluster` adopts that PVC (`storage.pvcTemplate` or recovery from an existing PVC per the CNPG docs). The volume lives in the persistent Civo network.
- **(c) Object store backup**: CIVO-180 becomes P1. This spec bootstraps from the latest backup.

Common to all options: `instances: 1`, 20 Gi, the `postgres-critical` PriorityClass, requests 250m/256Mi, and `wal_level` logical kept for future CDC.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven); `civo/postgres/*.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh` (`civo_recovery_handle`, `civo_backup`); `scripts/lib/persistent-civo-artifacts.sh` *(new, mirrors `persistent-ebs-artifacts.sh`)*; `scripts/persistent-down.sh` (civo artifacts cleanup).

## 6. Implementation steps

1. Unblock: read the spike section in `research.md`. Pick (a), (b), or (c). Update §4 and `decisions.md`.
2. Template the Cluster. The golden aws diff is empty.
3. Run `PROVIDER=civo make up`. Write test rows via the e2e Postgres test or `psql`.
4. Run `make down`. Verify that the snapshot/volume exists in the Civo account. Verify that the cluster is gone. Note the billing.
5. Run `make up`. Verify the rows. Verify that `argo-up` picked the newest artifact. Verify that pruning keeps 2.
6. Failure paths: when the Backup fails, `argo-down` exits non-zero and leaves the cluster (fail closed). With a bogus handle, `argo-up` fails recovery visibly, with no silent `initdb`.
7. `persistent-down` civo: it lists and deletes the retained artifacts, with confirmation.

## 7. Dependencies and blockers

Blocked by CIVO-020 (the mechanism). Needs 050 (the layout) and 100 (the app password Secret).

## 8. Acceptance criteria

- Rows survive one down/up cycle. A second cycle also passes.
- Artifact retention: the newest 2 are kept. Older artifacts are pruned. Costs are recorded.
- The fail-closed behaviors are verified.
- `cluster-down` never deletes the artifact. `persistent-down` deletes it, with confirmation.
- The AWS golden diff is empty. AWS down/up still restores (one AWS cycle after merge).

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: two civo cycles (~0.5 USD) and one AWS cycle (existing cost).

## 10. AWS regression protection

The Cluster template defaults equal the AWS file. The snapshot handling for aws is untouched. An AWS down/up run is recorded.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: revert the change. The retained artifacts stay until `persistent-down`.

## 12. Risks and unresolved questions

- A Civo snapshot restore into a new cluster may require the same region and the same network. The spike answers this.
- CNPG adoption of a pre-existing PVC in option (b) needs the exact CNPG API path. Check the version 0.29.0 chart/operator docs at implementation.

## 13. Definition of done

- [ ] Mechanism chosen and documented
- [ ] Two cycles with data evidence; failure paths; AWS cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.
