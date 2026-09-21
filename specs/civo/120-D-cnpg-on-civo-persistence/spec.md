---
id: "CIVO-120"
title: "CloudNativePG on Civo with data surviving make down and make up"
status: "DONE"
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
completed: "2026-09-16"
---

# CIVO-120 — CNPG on Civo with persistence

## 1. Outcome and rationale

A single-instance CNPG cluster runs on Civo storage with the app password
from External Secrets. Rows written before `make down` are present after
`make up`. The data of record lives in S3 as a physical backup — a base
backup plus a continuous WAL archive, written by CNPG's barman-cloud
plugin (ADR 0032). The Civo volume is disposable.

Because the archive is continuous, a row committed seconds before
`make down` is already durable off-cluster before the teardown starts.
Point-in-time recovery is available; the withdrawn logical-dump design
(ADR 0031) would have surrendered it.

## 2. Scope and non-goals

In scope:
- CNPG `Cluster` values for the Civo target.
- Wiring the backup mechanism from CIVO-180 into the `Cluster`, `argo-down` and `argo-up`.
- Two full down and up cycles that carry real rows.

Not in scope:
- The bucket, the sidecar image, the plugin, the `ObjectStore` and the IAM role (CIVO-180).
- Switching the AWS target to the same mechanism (CIVO-185, now needing a redesign).
- Replicas. `instances: 1` is explicit. A second instance doubles the volume and the memory cost and protects nothing across cluster deletion.

## 3. Current state / evidence

- `gitops/templates/platform/aws/postgres/cluster.yaml` sets `instances: 1`, `storage.size: {{ .Values.postgres.storageSize }}` (20Gi), `storageClass: ebs-delete`, and `nodeSelector workload-type: on-demand`. It has a dual bootstrap: `recovery` from `VolumeSnapshot lab-postgres-recovered` when a handle is set, else `initdb`. It sets `backup.volumeSnapshot.className: ebs-postgres-snapshot`.
- `recovered-snapshot.yaml` holds a `VolumeSnapshotContent` with `driver ebs.csi.aws.com`, `deletionPolicy Retain`, and a `snapshotHandle` from values. It uses client-side apply.
- `argo-down.sh:54-113` creates a CNPG `Backup` (volumeSnapshot) and prunes. `argo-up.sh:167-197` discovers the newest handle.
- The Civo `civo-volume` class is RWO and WaitForFirstConsumer, with Delete reclaim. The volumes survive cluster deletion (research.md).
- The `Cluster` template now lives at `gitops/templates/platform/shared/postgres/cluster.yaml` and renders on civo, delivered by CIVO-115.

## 4. Design and contracts

- Storage: `storageClass: civo-volume`, 20 Gi, reclaim `Delete`. The volume dies with the cluster by design.
- No `nodeSelector` on Civo. It keeps `priorityClassName: postgres-critical`, requests 250m and 256Mi, and `wal_level` logical for future change data capture.
- `spec.enablePDB: false` on Civo, set through values. CNPG creates a PodDisruptionBudget even for one instance, and that budget blocks a node from draining. This matters when the autoscaler lands in M2 (CIVO-170); with a fixed pool it is harmless but consistent.
- Bootstrap has two branches, mirroring the AWS file. When `postgres.backup.recoverServerName` is non-empty the Cluster uses `bootstrap.recovery` with `source: lab-postgres-previous` and an `externalClusters` entry pointing the plugin at that generation. Otherwise it uses `initdb`. **There is no `initdb` fallback on the recovery branch** — a loud failure beats silently wiping a recoverable database, the same philosophy as ADR 0013.
- `serverName` is generation-scoped. Each bring-up mints `lab-postgres-<UTC timestamp>` and recovers from the previous one. With a constant `serverName` a recovered cluster archives into the prefix it just recovered from and the timeline histories collide. The current generation is published to SSM `/<project>/persistent-civo/postgres-backup/server_name` as a plain `String`, written only after the root Application reports healthy, so a failed bring-up cannot burn the pointer.
- The credential reaches the backup sidecar as a mounted file. `Cluster.spec.projectedVolumeTemplate` mounts the `pgbackup-ra-cert` Secret and the `pgbackup-aws-config` ConfigMap at `/projected` on the `postgres` container, and the plugin copies that container's volume mounts onto its sidecar. `optional: true` on the Secret source is load-bearing: the sidecar is a native sidecar, so a projected source naming a missing Secret would block pod creation entirely.
- The AWS environment goes on `Cluster.spec.env`, not on `instanceSidecarConfiguration.env`. The postgres container's env is merged into the sidecar first and wins, and a change to `Cluster.spec.env` rolls the instance so it is actually applied.
- Backup count is bounded by `argo-up`, not by `retentionPolicy`. `retentionPolicy` matches `^[1-9][0-9]*[dwm]$` — it is a recovery window, and it prunes only from inside a live cluster, scoped to that cluster's own `serverName`. Because every bring-up mints a new generation, no live cluster ever owns an older prefix. `civo_prune_backup_generations()` keeps the newest `POSTGRES_BACKUP_KEEP_GENERATIONS` (default 2) and never deletes the current or the recovered-from generation. The 30-day S3 lifecycle rule is a backstop, not the retention mechanism.
- `argo-down` Civo branch: after automated sync is disarmed, force a final `pg_switch_wal()` and create a `Backup` with `method: plugin`, then wait. The step is best-effort — on failure or timeout it warns loudly, names the `ContinuousArchiving` condition, and the teardown proceeds. Continuous WAL archiving has already made every committed row durable, so a failed final backup costs replay time, not data.
- `argo-up` Civo branch: read the SSM pointer into `recoverServerName`, mint a new `serverName`, install, then publish the new pointer and prune old generations. There is no restore Job and no `PostSync` hook; recovery is CNPG's own bootstrap.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (values-driven); `gitops/templates/platform/civo/postgres/{barman-plugin-application,objectstore,aws-config,scheduled-backup}.yaml`; `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`; `scripts/argo-up.sh` (SSM pointer, generation pruning); `scripts/lib/provider.sh` (`civo_recovery_handle`, `civo_backup`, `civo_archiving_status`); `scripts/argo-down.sh` (call order); `scripts/persistent-down.sh` (bucket emptying, pointer deletion); `scripts/gitops-render-check.sh`.

No `scripts/lib/persistent-civo-artifacts.sh` was created. Nothing on Civo is a retained cloud artifact but the S3 objects themselves, so there is no per-artifact discovery to mirror from `persistent-ebs-artifacts.sh`.

## 6. Implementation steps

1. Confirm CIVO-180 delivered the bucket, the `pgbackup` role, the sidecar image, the plugin Application and the `ObjectStore`.
2. Add the Cluster wiring: `projectedVolumeTemplate`, `spec.env`, `spec.plugins` and the recovery bootstrap branch, all gated on the civo target.
3. Add the generation pointer and the generation pruning to `argo-up.sh`; rewrite `civo_backup()` and `civo_recovery_handle()`.
4. Empty the bucket and delete the pointer in `persistent-down.sh`, so the two can never disagree.
5. Run `PROVIDER=civo make full-up` from a cold start. Confirm `initdb`, a new generation, `ContinuousArchiving=True` and the pointer written.
6. Write rows, **including one written seconds before the teardown**. That row is what proves the last WAL segment reached S3; a row written minutes earlier does not.
7. Run `make down`, then `make up`. Confirm recovery from the previous generation, that every row and table is present, and that new archiving goes to a **different** prefix.
8. Repeat step 7 once. The second cycle is the one that matters: it recovers from a cluster that was itself recovered.

## 7. Dependencies and blockers

CIVO-050 provides the layout, CIVO-100 the database password, CIVO-180 the bucket and the jobs.

## 8. Acceptance criteria

- Rows and schema survive two down and up cycles, including a row committed seconds before teardown, and including a cycle that recovers from an already-recovered cluster.
- Each generation archives into its own prefix, and the timeline history files do not collide.
- The pre-teardown backup is best-effort: it runs, it is waited for, and a failure warns loudly without blocking the teardown (ADR 0032, constitution §4). The archiving state is read **before** the teardown proceeds, and an unhealthy state names the writes being destroyed.
- The stored backup count is bounded. `argo-up` keeps the newest two generations and refuses to delete the current or the recovered-from one.
- `cluster-down` never touches the bucket. `persistent-down` empties it and deletes the SSM pointer, under the existing `CONFIRM_DESTROY` prompt.
- The `platform` and `platform-recovery` goldens are unchanged. The `bootstrap` golden gains only the new empty-valued Helm parameters, reviewed line by line. One AWS down and up cycle still restores from its EBS snapshot.

## 9. Validation

Offline: `make gitops-check` (the golden diff and kubeconform), `bash -n` and `shellcheck` on every changed script. Note that this repository has no PR-triggered CI — `.github/workflows/` holds only `lab.yml`, `lifecycle-test.yml` and `sidecar-image.yml` — so these run locally.

Real cloud: one cold `full-down`/`full-up`, two civo down/up cycles (~0.75 USD of Civo compute, ~0.25 USD per month of S3) and one AWS cycle (existing cost).

## 10. AWS regression protection

Every new block in the shared `cluster.yaml` is gated on `eq .Values.target "civo"`, so the AWS render is byte-identical — proved by the empty `platform` and `platform-recovery` golden diff. The snapshot discovery in `argo-up.sh` and the `volumeSnapshot` backup in `argo-down.sh` are untouched.

An AWS `make down` / `make up` cycle was run on 2026-09-16 and the EBS `VolumeSnapshot` path still restored. **This is operator-reported; no command output was captured into this spec.** A future change to the shared template should re-run it and record the output.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: revert the change. The retained artifacts stay until `persistent-down`.

## 12. Risks and unresolved questions

- **Open, data-safety path: "the pointer exists but the bucket is empty" has never been exercised.** The recovery branch has no `initdb` fallback by design, so this state must fail loudly rather than start an empty database that looks healthy. `persistent-down` deletes the pointer together with the bucket, which is what keeps the two from disagreeing — but a hand-emptied bucket, or a prune bug, would reach it. Not proven. Exercise it before relying on the failure being loud.
- Two further paths are untested and degrade only to a warning: `civo_prune_backup_generations()` has never run inside a real `argo-up` (it was verified standalone against the live bucket), and the unhealthy-archiving warning has never run against an unhealthy cluster — archiving was `True` on every teardown. Both self-exercise on ordinary bring-ups.
- **No Civo e2e assertion exists.** `tests/e2e/postgres_test.go` asserts nothing about `ContinuousArchiving` or about a `completed` Backup, so a silent archiving failure would not fail a test. The read-only e2e ClusterRole would also need `backups.postgresql.cnpg.io` and `objectstores.barmancloud.cnpg.io`, which touches the AWS golden. Carried to CIVO-150.
- The base-backup duration for a 20 GiB volume sets `ARGO_DOWN_BACKUP_TIMEOUT` (600s on Civo). It completed in 15–20s at lab data volumes. Re-measure if the database grows.
- **Update (2026-09-09, from CIVO-060):** `root` now reaches `Synced/Healthy` on civo — CIVO-060's `Gateway` resource is the first thing in civo's root tree with a real ArgoCD health check, and a live bring-up reached `Synced/Healthy` well inside the shortened 300s window (with one transient `Degraded` blip while the Gateway's conditions settled). `scripts/argo-up.sh` still keeps `WATCH_SECONDS` at 300s on civo (`TODO(civo)` comment at the assignment), deliberately, because this was observed on one run, not proven stable across repeated cycles. This spec should re-run a few civo up/down cycles once the CNPG `Cluster` resource lands, confirm `Synced/Healthy` is reached reliably every time (not just once), and only then remove the shortened default so civo shares AWS's 2700s timeout again.

## 13. Definition of done

- [x] Mechanism chosen and documented (ADR 0032; ADR 0031 superseded; constitution §4 amended)
- [x] A cold start plus two down/up cycles with row, schema and timeline evidence, including a row committed seconds before each teardown (§14)
- [x] One AWS down/up cycle confirming the EBS `VolumeSnapshot` path still restores — operator-reported, see §10
- [x] Index updated; status `DONE`

Not claimed: the three failure paths listed in §12 were not exercised, and
no Civo e2e assertion exists. Neither blocks this spec — the recovery path
itself is proven — but both are real gaps and are named rather than hidden.

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

- 2026-09-16 — **archiving state is now read before teardown, not only after a failure.** The constitution §4 relaxation as first written promised the best-effort path applied "only where continuous archiving is verified healthy", but nothing read that condition until `civo_backup_warn()` ran, which happens only after a backup has already failed. `civo_backup()` now reads `ContinuousArchiving` first. It still never blocks — teardown proceeds either way, per the operator decision that teardown needs no confirmation — but when the condition is not `True` it warns that writes since `lastTransitionTime` have not reached S3 and are destroyed by this teardown. §4 is reworded to match: the state MUST be read and the loss MUST be stated, not that the state MUST be healthy.

  Two deviations from the plan are recorded rather than hidden. Task 10 specified "force a final `pg_switch_wal()` **and wait for `ContinuousArchiving`**"; the implementation reads the condition up front and does not re-wait after the switch. Both cycles recovered their final row regardless, so the margin in practice is the backup's own ~20 s duration rather than an assertion. And this warning path has not run against an unhealthy cluster — archiving was `True` on every teardown in the cycle test.

- 2026-09-16 — **AWS regression cycle run by the operator; spec closed.** One AWS `make down` / `make up` completed and the EBS `VolumeSnapshot` path still restored. No command output was captured, so §10 records it as operator-reported rather than as a verified transcript.

  §§1, 4, 5, 6, 8, 9, 10 and 12 were rewritten from the withdrawn logical-dump design to the shipped one. Two acceptance criteria were deleted because what ships now does the opposite of what they asserted: *"The teardown gate fails closed on a failed dump"* (reversed by ADR 0032 and constitution §4) and *"The AWS golden diff is empty"* (the `bootstrap` golden necessarily gains the new empty-valued Helm parameters; the `platform` and `platform-recovery` goldens are the ones that stay unchanged). §5's `scripts/lib/persistent-civo-artifacts.sh` was deleted from the file list — it was never created and is unnecessary. The "Superseded in part" blockquote above §4 is gone: the section now describes what shipped, and this history stays here.

  Status `DONE`. The gaps in §12 are open work, not unfinished work in this spec.
- 2026-09-20 — HETZ-016: `platform/civo/postgres/aws-config.yaml` moved to `platform/shared/postgres/aws-config.yaml`, gated by `platform.selfManaged`.
