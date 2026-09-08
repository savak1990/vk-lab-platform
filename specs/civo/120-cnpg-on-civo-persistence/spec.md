---
id: "CIVO-120"
title: "CloudNativePG on Civo with data surviving make down and make up"
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
from External Secrets. Rows written before `make down` are present after
`make up`. The data of record lives in S3 as a logical dump, written by
the shared backup job from CIVO-180. The Civo volume is disposable.

## 2. Scope and non-goals

In scope:
- CNPG `Cluster` values for the Civo target.
- Wiring the shared backup and restore jobs into `argo-down` and `argo-up`.
- Two full down and up cycles that carry real rows.

Not in scope:
- The bucket, the image, the CronJob, the restore Job and the IAM roles (CIVO-180).
- Switching the AWS target to the same mechanism (CIVO-185).
- Replicas. `instances: 1` is explicit. A second instance doubles the volume and the memory cost and protects nothing across cluster deletion.

## 3. Current state / evidence

- `gitops/templates/platform/aws/postgres/cluster.yaml` sets `instances: 1`, `storage.size: {{ .Values.postgres.storageSize }}` (20Gi), `storageClass: ebs-delete`, and `nodeSelector workload-type: on-demand`. It has a dual bootstrap: `recovery` from `VolumeSnapshot lab-postgres-recovered` when a handle is set, else `initdb`. It sets `backup.volumeSnapshot.className: ebs-postgres-snapshot`.
- `recovered-snapshot.yaml` holds a `VolumeSnapshotContent` with `driver ebs.csi.aws.com`, `deletionPolicy Retain`, and a `snapshotHandle` from values. It uses client-side apply.
- `argo-down.sh:54-113` creates a CNPG `Backup` (volumeSnapshot) and prunes. `argo-up.sh:167-197` discovers the newest handle.
- The Civo `civo-volume` class is RWO and WaitForFirstConsumer, with Delete reclaim. The volumes survive cluster deletion (research.md).

## 4. Design and contracts

- Storage: `storageClass: civo-volume`, 20 Gi, reclaim `Delete`. The volume dies with the cluster by design.
- No `nodeSelector` on Civo. It keeps `priorityClassName: postgres-critical`, requests 250m and 256Mi, and `wal_level` logical for future change data capture.
- `spec.enablePDB: false` on Civo, set through values. CNPG creates a PodDisruptionBudget even for one instance, and that budget blocks a node from draining. This matters when the autoscaler lands in M2 (CIVO-170); with a fixed pool it is harmless but consistent.
- Bootstrap is always `initdb`. The cluster starts empty on every `make up`, and the restore Job from CIVO-180 loads the newest dump when the schema is empty. There is no recovery bootstrap and no snapshot handle.
- `argo-down` Civo branch: run the teardown dump gate from CIVO-180 before the cascade. On failure it exits non-zero and leaves the cluster running, unless `CI_TEARDOWN_ALLOW_DATA_LOSS=1` is set.
- `argo-up` needs no backup logic. The restore Job runs as a `PostSync` hook once the Postgres Application is healthy, and decides for itself whether to load a dump.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven); `civo/postgres/*.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh` (`civo_recovery_handle`, `civo_backup`); `scripts/lib/persistent-civo-artifacts.sh` *(new, mirrors `persistent-ebs-artifacts.sh`)*; `scripts/persistent-down.sh` (civo artifacts cleanup).

## 6. Implementation steps

1. Confirm CIVO-180 delivered the bucket, the image, the CronJob and the restore Job.
2. Template the `Cluster` with values. Run `make gitops-check`; the AWS golden diff must be empty.
3. Run `PROVIDER=civo make up`. Write test rows through the end-to-end Postgres test or `psql`.
4. Run `make down`. Confirm the teardown dump completed and the object is in S3.
5. Run `make up`. Confirm the restore Job loaded the dump and the rows are present.
6. Repeat steps 4 and 5 once more.
7. Re-sync Argo without a teardown. Confirm the restore Job exits successfully and changes nothing, because the schema is not empty.
8. Failure paths: a failed teardown dump exits non-zero and leaves the cluster; a corrupt or missing dump fails the restore Job visibly instead of leaving an empty database that looks healthy.

## 7. Dependencies and blockers

CIVO-050 provides the layout, CIVO-100 the database password, CIVO-180 the bucket and the jobs.

## 8. Acceptance criteria

- Rows survive two down and up cycles.
- A re-sync without a teardown does not touch existing data.
- The teardown gate fails closed on a failed dump.
- `cluster-down` never touches the bucket. `persistent-down` empties it only after a confirmation.
- The AWS golden diff is empty, and one AWS down and up cycle still restores from its EBS snapshot.

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: two civo cycles (~0.5 USD) and one AWS cycle (existing cost).

## 10. AWS regression protection

The Cluster template defaults equal the AWS file. The snapshot handling for aws is untouched. An AWS down/up run is recorded.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: revert the change. The retained artifacts stay until `persistent-down`.

## 12. Risks and unresolved questions

- The dump and restore duration for a 20 GiB volume sets the teardown timeout. Measure once and adjust.
- A logical dump restores to the moment of the dump. Rows written after the last dump and before an unplanned cluster loss are gone. The teardown gate bounds that window for planned teardowns; the daily schedule bounds it otherwise.
- The restore Job must detect an empty schema reliably. Counting tables in the application schema is the chosen test.
- `scripts/argo-up.sh` currently shortens `WATCH_SECONDS` to 300s on civo (`TODO(civo)` comment at the assignment) because nothing in `root`'s tree gets an ArgoCD health check yet (CIVO-045 §8). Once this spec adds the CNPG `Cluster` resource, check whether `root` can reach `Synced/Healthy` on civo and, if so, remove that shortened default so civo shares AWS's 2700s timeout again.

## 13. Definition of done

- [ ] Mechanism chosen and documented
- [ ] Two cycles with data evidence; failure paths; AWS cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.

- 2026-09-06 — kubernetes-architect review: `csi.civo.com` advertises no `CREATE_DELETE_SNAPSHOT` or `CLONE_VOLUME` capability (https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go). Snapshot and PVC-datasource recovery dropped; redesigned around object-store backups; blocker removed; status READY with new dependency CIVO-180.

- 2026-09-06 — user decision: persistence moves from object-store barman backups to shared logical dumps in S3. The Civo Object Store bills a 500 GB minimum; S3 bills bytes stored. This spec now depends on CIVO-180 for the mechanism.

