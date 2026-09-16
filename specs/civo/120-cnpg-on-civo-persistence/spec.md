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
depends_on: ["CIVO-050", "CIVO-100", "CIVO-115", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-16"
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
- The `Cluster` template now lives at `gitops/templates/platform/shared/postgres/cluster.yaml` and renders on civo, delivered by CIVO-115.

## 4. Design and contracts

> **Superseded in part on 2026-09-16.** The mechanism is now CNPG's
> barman-cloud plugin, not logical dumps. The bullets below about `initdb`-only
> bootstrap, the restore Job, and the fail-closed teardown gate no longer hold.
> §14's 2026-09-16 entries are the current contract until this section is
> rewritten.

- Storage: `storageClass: civo-volume`, 20 Gi, reclaim `Delete`. The volume dies with the cluster by design.
- No `nodeSelector` on Civo. It keeps `priorityClassName: postgres-critical`, requests 250m and 256Mi, and `wal_level` logical for future change data capture.
- `spec.enablePDB: false` on Civo, set through values. CNPG creates a PodDisruptionBudget even for one instance, and that budget blocks a node from draining. This matters when the autoscaler lands in M2 (CIVO-170); with a fixed pool it is harmless but consistent.
- Bootstrap is always `initdb`. The cluster starts empty on every `make up`, and the restore Job from CIVO-180 loads the newest dump when the schema is empty. There is no recovery bootstrap and no snapshot handle.
- `argo-down` Civo branch: after automated sync is disarmed, force a final `pg_switch_wal()` and create a `Backup` with `method: plugin`, then wait. The step is best-effort — on failure or timeout it warns loudly, names the `ContinuousArchiving` condition, and the teardown proceeds. Continuous WAL archiving has already made every committed row durable, so a failed final backup costs replay time, not data.
- `argo-up` needs no backup logic. The restore Job runs as a `PostSync` hook once the Postgres Application is healthy, and decides for itself whether to load a dump.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven); `civo/postgres/*.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh` (`civo_recovery_handle`, `civo_backup`); `scripts/lib/persistent-civo-artifacts.sh` *(new, mirrors `persistent-ebs-artifacts.sh`)*; `scripts/persistent-down.sh` (civo artifacts cleanup).

## 6. Implementation steps

1. Confirm CIVO-180 delivered the bucket, the image, the CronJob and the restore Job.
2. Run `PROVIDER=civo make up`. Write test rows through the end-to-end Postgres test or `psql`.
3. Run `make down`. Confirm the teardown dump completed and the object is in S3.
4. Run `make up`. Confirm the restore Job loaded the dump and the rows are present.
5. Repeat steps 3 and 4 once more.
6. Re-sync Argo without a teardown. Confirm the restore Job exits successfully and changes nothing, because the schema is not empty.
7. Failure paths: a failed teardown dump exits non-zero and leaves the cluster; a corrupt or missing dump fails the restore Job visibly instead of leaving an empty database that looks healthy.

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
- **Update (2026-09-09, from CIVO-060):** `root` now reaches `Synced/Healthy` on civo — CIVO-060's `Gateway` resource is the first thing in civo's root tree with a real ArgoCD health check, and a live bring-up reached `Synced/Healthy` well inside the shortened 300s window (with one transient `Degraded` blip while the Gateway's conditions settled). `scripts/argo-up.sh` still keeps `WATCH_SECONDS` at 300s on civo (`TODO(civo)` comment at the assignment), deliberately, because this was observed on one run, not proven stable across repeated cycles. This spec should re-run a few civo up/down cycles once the CNPG `Cluster` resource lands, confirm `Synced/Healthy` is reached reliably every time (not just once), and only then remove the shortened default so civo shares AWS's 2700s timeout again.

## 13. Definition of done

- [ ] Mechanism chosen and documented
- [ ] Two cycles with data evidence; failure paths; AWS cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.

- 2026-09-06 — kubernetes-architect review: `csi.civo.com` advertises no `CREATE_DELETE_SNAPSHOT` or `CLONE_VOLUME` capability (https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go). Snapshot and PVC-datasource recovery dropped; redesigned around object-store backups; blocker removed; status READY with new dependency CIVO-180.

- 2026-09-06 — user decision: persistence moves from object-store barman backups to shared logical dumps in S3. The Civo Object Store bills a 500 GB minimum; S3 bills bytes stored. This spec now depends on CIVO-180 for the mechanism.

- 2026-09-11 — CNPG Cluster delivery split out to CIVO-115 (runs on civo with disposable data); this spec keeps the persistence proof.


- 2026-09-16 — mechanism reopened and changed. ADR 0031 rejected the CNPG barman-cloud plugin on the premise that "CNPG has no supported way to add a container of one's own to its managed instance pods". That premise is false: the plugin injects its own sidecar, `SIDECAR_IMAGE` selects that sidecar's image, and `internal/cnpgi/operator/lifecycle.go` copies the `postgres` container's volume mounts onto it (`sidecar.VolumeMounts = ensureVolumeMount(sidecar.VolumeMounts, spec.Containers[i].VolumeMounts...)`). Physical backups with point-in-time recovery are therefore available on Civo, and the logical-dump design is withdrawn. Credentials reach the sidecar through `credential_process`, not a Secret and not a background listener.

- 2026-09-16 — **spike executed against a live Civo cluster; all four gates passed.** Bucket `vk-civo-lab-postgres-backups`, role `vk-civo-lab-ra-pgbackup`, CloudNativePG 1.30.0, plugin chart 0.8.0 (app v0.15.0), sidecar image `ghcr.io/savak1990/vk-lab-platform/cnpg-barman-sidecar@sha256:25332843178ff9560b176f7c6c22006c1b361cb249bae7f52728d733f7d98cda`.

  **(a) The projected mount is inherited by the sidecar.** `Cluster.spec.projectedVolumeTemplate` mounts at `/projected` on the `postgres` container, and the same mount appears on the `plugin-barman-cloud` container. That container is an initContainer with `restartPolicy: Always` — a native sidecar — and `instanceSidecarConfiguration` exposes no `volumeMounts` field, so inheritance is the only route a file has into it.

  **(b) S3 works with no AWS key anywhere.** The sidecar carried exactly three AWS variables, all supplied by `Cluster.spec.env`: `AWS_CONFIG_FILE=/projected/aws/config`, `AWS_REGION`, `AWS_DEFAULT_REGION`. `s3Credentials.inheritFromIAMRole: true` kept barman from appending its own. `ContinuousArchiving=True`; a `Backup` with `method: plugin` reached `completed`; 65 objects landed, including `base/20260916T093447/{data.tar.gz,backup.info}`.

  **(c) Certificate rotation is survived.** Tested with a deliberately short certificate — `duration: 1h, renewBefore: 55m`, rotating about every five minutes. Over 58 checks across 59 minutes: **12 rotations, 0 archiving failures.** The discriminating evidence is not elapsed time but the `notAfter` of the certificate present at pod start (serial `39098BF5…`, expiring `10:31:22Z`): five WAL segments were written after it, the last at `10:35:32Z`. A cached certificate would have failed `CreateSession` at `10:31:22Z`. It does not cache, because `credential_process` spawns a fresh process per credential fetch and botocore refetches only when under 15 minutes of session life remain.

  **(d) RBAC — finding, not a blocker.** The plugin generates `Role/lab-postgres-barman-cloud` whose secrets rule carries an **empty** `resourceNames`: `[""] ["secrets"] ["get","watch","list"]`. That is read access to every Secret in `cnpg-system`, including `lab-postgres-app` and `pgbackup-ra-cert`. It applied cleanly because this repo runs no restrictive operator RBAC (upstream issue #892 reports it failing where such RBAC exists). Carry it into the least-privilege review, CIVO-205.

  **Also settled.** The chart composes `registry/repository:tag` and cannot take a bare digest, but `tag@digest` renders a valid reference that resolves by digest — so digest pinning needs no `SIDECAR_IMAGE` override. Argo CD v3.5.1 accepts an `oci://` chart source. The shared Roles Anywhere profile's 3600s duration needs no change: it clears botocore's 15-minute refresh threshold four times over, and raising it would also raise it for eso, external-dns and cert-manager.

  The spike ran on a hand-patched Cluster with Argo `selfHeal` disarmed. Nothing here is committed; the manifests land in this spec's implementation.

- 2026-09-16 — **implementation merged and verified on the live cluster.** PR #7 (`330fd65`) added the plugin Application, the `ObjectStore`, the `pgbackup-aws-config` ConfigMap, the `ScheduledBackup`, the Cluster wiring (`projectedVolumeTemplate`, `spec.env`, `spec.plugins`, the recovery bootstrap branch), the values in all three places, the `argo-up` generation pointer and the render-check assertions. All 7 Applications reached `Synced/Healthy`, which also confirms Argo CD v3.5.1 accepts an `oci://` chart source. `ContinuousArchiving=True`; `ScheduledBackup` with `immediate: true` produced Backup `lab-postgres-20260916165449` (`method: plugin`) in `completed`; objects landed under `lab-postgres-20260916T164227Z/base/20260916T165455/`. The root Application was then repointed from the feature branch to `main` and re-verified `Synced/Healthy` at `330fd65` with archiving still `True`.

- 2026-09-16 — **ADR 0032 written; ADR 0031 superseded.** Constitution §4 gains an explicit relaxation: where a workload archives continuously, a final pre-shutdown backup is best-effort rather than fail-closed. `CI_TEARDOWN_ALLOW_DATA_LOSS` is removed from every live contract in the repository. It survives only in the body of CIVO-115, which is `DONE` — deleting it there would falsify the record of what that spec delivered, so a superseded blockquote directs readers not to re-implement the gate. `civo_backup()` now forces a final `pg_switch_wal()`, creates a `Backup` with `method: plugin`, waits up to 600s, and warns loudly rather than failing. It runs after the Argo disarm loop, alongside the AWS path, rather than before it.

- 2026-09-16 — **full cold-start and two recovery cycles executed end to end; all gates passed.** Sequence: `full-down` (destroying the bucket, the trust anchor and the terraform state), `full-up`, then two `make down` / `make up` cycles, with rows written in each.

  **Cold start.** `full-down` exited 0. The pre-teardown backup ran on its first live exercise: WAL switch forced, `Backup` with `method: plugin` `completed` in 15s. `persistent-down` counted 78 backup objects, emptied the bucket, and destroyed the `backups` unit cleanly — `force_destroy` is false, so an unemptied bucket would have failed the destroy. `full-up` exited 0 and minted generation `lab-postgres-20260916T175424Z` with `bootstrap.initdb`, because the `server_name` pointer had been deleted with the bucket.

  **The cold-start ordering hazard did not materialise.** The `pgbackup` certificate was issued at `17:57:56Z`; the Postgres pod started at `18:02:07Z`, four minutes later. `ContinuousArchiving` went `True` at `18:02:37Z` and never went `False`. The sidecar log contains zero occurrences of error, denied or fail. `optional: true` on the projected Secret was therefore not exercised as a recovery path on this run — it remains correct as a guard, but the wave-3 Cluster did not race cert-manager here.

  **Cycle 1 — recovery from a fresh cluster.** Four `cycle0` rows were written, the last (`FINAL-ROW-BEFORE-TEARDOWN`, id 4) at `18:03:59Z`, seconds before `make down`. After `make up`, the Cluster showed `bootstrap.recovery` with `source: lab-postgres-previous`, `externalClusters[0].serverName = lab-postgres-20260916T175424Z`, and a new archive target `lab-postgres-20260916T181622Z`. All four rows were present, including the final one, and table `ddl_proof_cycle0` was recovered — so schema, not only rows.

  **Cycle 2 — recovery from a cluster that was itself recovered.** This is the case the generation-scoped `serverName` exists for. Four `cycle1` rows were written, the last at `18:24:55Z`. After `make up`: recovery from `lab-postgres-20260916T181622Z`, archiving to `lab-postgres-20260916T183600Z`, `ContinuousArchiving=True`. **All eight rows across both cycles were present, both `FINAL-ROW-BEFORE-TEARDOWN` rows and both `ddl_proof_*` tables.**

  **Timeline separation is confirmed directly.** Each generation holds its own history file and nothing else: `lab-postgres-20260916T181622Z/wals/00000002.history.gz` and `lab-postgres-20260916T183600Z/wals/00000003.history.gz`. `pg_control_checkpoint()` reported `timeline_id = 3`. With a constant `serverName` these would have collided in one prefix.

- 2026-09-16 — **retention finding: old generations are never pruned.** After the cycles the bucket held three prefixes with 11, 13 and 8 objects. `retentionPolicy: "2d"` is a recovery window and prunes only from inside a live cluster, scoped to that cluster's own `serverName`. Every bring-up mints a new generation, so no live cluster ever owns an older prefix and barman never prunes one. Old generations age out only through the 30-day S3 lifecycle rule, which is a backstop, not a retention mechanism. The effective bound today is "every generation from the last 30 days", not a backup count — and a backup count is not expressible, because `retentionPolicy` matches `^[1-9][0-9]*[dwm]$`. At lab scale this is roughly 20 MB per cycle. Capping it properly needs `argo-up` to delete generation prefixes older than the one it recovers from; that is not implemented.

- 2026-09-16 — **generation pruning added to `argo-up`, closing the retention finding above.** After the pointer is written, `civo_prune_backup_generations()` lists generation prefixes, keeps the newest `POSTGRES_BACKUP_KEEP_GENERATIONS` (default 2) and deletes the rest. It only considers prefixes matching `^lab-postgres-[0-9]{8}T[0-9]{6}Z$`, so anything placed in the bucket by hand is left alone, and it refuses to delete the current or the recovered-from generation by name rather than trusting the sort. A failure warns and the bring-up continues; the 30-day lifecycle rule remains the backstop.

  Verified against the live bucket holding three generations: the prune deleted the oldest and left the current and recovered-from prefixes, a second run reported `2 backup generation(s) stored, keeping 2 - nothing to prune`, and a run with `POSTGRES_BACKUP_KEEP_GENERATIONS=1` selected the recovered-from generation for deletion and then correctly refused it, leaving both prefixes intact. This is what actually bounds the stored backup count; `retentionPolicy` bounds only the recovery window inside one generation.
