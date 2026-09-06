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

A single-instance CNPG cluster runs on Civo storage with the app password
from ESO; rows written before `make down` are present after `make up`.
Persistence on Civo must be proven against real account resources, not
assumed from a surviving PVC.

## 2. Scope and non-goals

In scope: CNPG `Cluster` values for civo, the persistence mechanism chosen
by CIVO-020, `argo-up`/`argo-down` civo persistence functions, recovery
template. Not in scope: backups to object storage (CIVO-180), replicas
(explicitly `instances: 1`; a second instance doubles volume and RAM and
gives no protection across cluster deletion).

## 3. Current state / evidence

- `gitops/templates/platform/aws/postgres/cluster.yaml`: `instances: 1`, `storage.size: {{ .Values.postgres.storageSize }}` (20Gi), `storageClass: ebs-delete`, `nodeSelector workload-type: on-demand`, dual bootstrap (`recovery` from `VolumeSnapshot lab-postgres-recovered` when a handle is set, else `initdb`), `backup.volumeSnapshot.className: ebs-postgres-snapshot`.
- `recovered-snapshot.yaml`: `VolumeSnapshotContent` with `driver ebs.csi.aws.com`, `deletionPolicy Retain`, `snapshotHandle` from values, client-side apply.
- `argo-down.sh:54-113` creates a CNPG `Backup` (volumeSnapshot) and prunes; `argo-up.sh:167-197` discovers the newest handle.
- Civo `civo-volume`: RWO, WaitForFirstConsumer, Delete reclaim, volumes survive cluster deletion (research.md).

## 4. Design and contracts

Mechanism per CIVO-020 result:

- **(a) VolumeSnapshot** (preferred): `civo/postgres/volumesnapshotclass.yaml` (`driver csi.civo.com`, `deletionPolicy Retain`); `Cluster` on civo uses `storageClass: civo-volume`, no nodeSelector, `backup.volumeSnapshot.className: civo-postgres-snapshot`; `recovered-snapshot.yaml` templated by `.Values.storage.snapshotDriver`; `argo-down` civo runs the same Backup and prunes via the Civo API/CLI keeping the newest 2; `argo-up` discovers the newest handle via the Civo API.
- **(b) Retained volume**: StorageClass `civo-retain` (`reclaimPolicy Retain`); `argo-down` records the volume ID to SSM `/${project}/persistent/civo/postgres/volume_id`; `argo-up` renders a static `PV` bound by `volumeHandle` and a pre-bound PVC name that CNPG's `Cluster` adopts (`storage.pvcTemplate` or recovery from an existing PVC per CNPG docs); the volume lives in the persistent Civo network.
- **(c) Object store backup**: CIVO-180 becomes P1 and this spec bootstraps from the latest backup.

Common: `instances: 1`, 20 Gi, `postgres-critical` PriorityClass, requests 250m/256Mi, `wal_level` logical kept for future CDC.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven), `civo/postgres/*.yaml`, `scripts/argo-up.sh`, `scripts/argo-down.sh` (`civo_recovery_handle`, `civo_backup`), `scripts/lib/persistent-civo-artifacts.sh` *(new, mirrors `persistent-ebs-artifacts.sh`)*, `scripts/persistent-down.sh` (civo artifacts cleanup).

## 6. Implementation steps

1. Unblock: read the spike section in `research.md`; pick (a)/(b)/(c); update §4 and `decisions.md`.
2. Template the Cluster; golden aws diff empty.
3. `PROVIDER=civo make up`; write test rows via the e2e Postgres test or `psql`.
4. `make down`; verify the snapshot/volume exists in the Civo account and the cluster is gone; note billing.
5. `make up`; verify rows; verify `argo-up` picked the newest artifact; verify pruning keeps 2.
6. Failure paths: `argo-down` when Backup fails → exits non-zero and leaves the cluster (fail closed); `argo-up` with a bogus handle → recovery fails visibly, no silent `initdb`.
7. `persistent-down` civo: lists and deletes retained artifacts with confirmation.

## 7. Dependencies and blockers

Blocked by CIVO-020 (mechanism). Needs 050 (layout) and 100 (app password Secret).

## 8. Acceptance criteria

- Rows survive one down/up cycle; a second cycle also passes.
- Artifact retention: newest 2 kept; older pruned; costs recorded.
- Fail-closed behaviors verified.
- `cluster-down` never deletes the artifact; `persistent-down` does, with confirmation.
- AWS golden diff empty; AWS down/up still restores (one AWS cycle after merge).

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: two civo cycles (~0.5 USD); one AWS cycle (existing cost).

## 10. AWS regression protection

Cluster template defaults equal the AWS file; snapshot handling for aws untouched; AWS down/up run recorded.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: revert; retained artifacts stay until `persistent-down`.

## 12. Risks and unresolved questions

- Civo snapshot restore into a new cluster may require same-region and same-network; spike answers.
- CNPG adoption of a pre-existing PVC in option (b) needs the exact CNPG API path; version 0.29.0 chart/operator docs at implementation.

## 13. Definition of done

- [ ] Mechanism chosen and documented
- [ ] Two cycles with data evidence; failure paths; AWS cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.
