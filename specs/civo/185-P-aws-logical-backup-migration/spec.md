---
id: "CIVO-185"
title: "Move the AWS target to the CNPG barman-cloud plugin"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "It replaces the data-recovery path of the working AWS platform, must cut over without a bring-up that wipes the lab database, and depends on two unproven identity and architecture behaviours"
effort_estimate: "Two sessions (8–12 h) plus three AWS down/up cycles and one Civo down/up cycle"
estimate_confidence: "medium"
depends_on: ["CIVO-120", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-17"
completed: null
---

# CIVO-185 — Move the AWS target to the CNPG barman-cloud plugin

## 1. Outcome and rationale

The AWS target backs up PostgreSQL through the same barman-cloud CNPG-I
plugin that Civo uses (ADR 0032): continuous WAL archiving and scheduled
base backups to a per-project S3 bucket, and recovery through CNPG's
`bootstrap.recovery` from the previous generation. The EBS
`VolumeSnapshot` mechanism (ADR 0013) retires.

Three things are gained:

- **Point-in-time recovery on AWS.** A cold `VolumeSnapshot` taken at
  teardown gives none, and it fences the primary while it runs.
- **One mechanism.** One set of templates, one recovery branch, one
  generation pointer, one set of e2e assertions (CIVO-150) for both
  providers.
- **Less surface.** The snapshot controller, the snapshot class, the
  client-side-applied `VolumeSnapshotContent`, the root Application's
  `ignoreDifferences` entry and the snapshot discovery and prune code
  all go.

AWS is the simpler half. EKS Pod Identity supplies credentials, so none of
the Civo identity machinery — `aws_signing_helper`, `credential_process`,
`projectedVolumeTemplate`, the custom sidecar image — is used on AWS. The
upstream sidecar image is multi-arch and is used unmodified.

## 2. Scope and non-goals

In scope:

- A `persistent/backups` Terraform unit for AWS, using the existing `postgres-backups` module. The Civo unit stays where it is.
- A Pod Identity role and association for the Postgres instance pods on AWS.
- Moving the plugin Application, `ObjectStore` and `ScheduledBackup` templates from Civo-only to shared.
- Provider-neutral generation-pointer, prune, teardown-backup and recovery-handle helpers in the scripts.
- Pinning one PostgreSQL image on both targets.
- A cutover order in which both mechanisms are live for one cycle, so no bring-up falls through to `initdb` over real data.
- Retiring the AWS snapshot create, discover and prune paths, and the snapshot manifests.
- ADR 0033 superseding ADR 0013; architecture and AWS design documents.
- Three AWS cycles (one with both mechanisms live) and one Civo regression cycle, with data evidence.

Not in scope:

- **Cross-provider restore.** CIVO-186 was removed on 2026-09-16. Buckets and pointers are per project, a shared bucket would let a leaked `CIVO_TOKEN` read AWS data through the ADR 0030 CA-key path, and AWS runs arm64 while Civo runs x86_64: PostgreSQL does not support physical restore across architectures, and `char` signedness differs, so some index keys (for example `pg_trgm` GIN) would need a rebuild.
- Deleting existing EBS snapshots by hand. They remain the rollback path. `persistent-down` still deletes them, as it does today.
- An arm64 build of `images/cnpg-barman-sidecar`. AWS does not use it; HETZ-182 owns that.

## 3. Current state / evidence

- `scripts/argo-down.sh:87-150` `aws_cnpg_backup_and_prune` creates a `Backup` with `method: volumeSnapshot`, fails closed on failure or timeout, then prunes EBS snapshots to the newest 2.
- `scripts/argo-up.sh:309-353` `aws_resolve_snapshot` discovers the newest completed snapshot, prunes, and sets `RECOVERY_SNAPSHOT_HANDLE`; `aws_install_root_application` passes it as `postgres.recoverySnapshotHandle`.
- `gitops/templates/platform/aws/postgres/recovered-snapshot.yaml` builds a `VolumeSnapshotContent` and `VolumeSnapshot`; `gitops/templates/platform/aws/ebs-csi/{snapshot-controller,volumesnapshotclass}.yaml` install the controller, its CRDs and the class.
- `gitops/bootstrap/templates/root-application.yaml:28-29` passes `postgres.recoverySnapshotHandle`; `:88-92` ignores differences on `VolumeSnapshotContent`.
- `gitops/templates/platform/shared/postgres/cluster.yaml` renders a `volumeSnapshot` backup block and a snapshot recovery branch on aws, and the plugin blocks on civo only. It sets no `imageName`, so both targets take the operator chart 0.29.0 default image.
- `gitops/templates/platform/civo/postgres/{barman-plugin-application,objectstore,scheduled-backup,aws-config}.yaml` are gated on `target == civo`.
- `terraform/live/persistent-civo/backups` uses `terraform/modules/postgres-backups` and holds the live Civo bucket `vk-civo-lab-postgres-backups`. SSM: `/<project>/persistent-civo/backups/bucket_name` and the pointer `/<project>/persistent-civo/postgres-backup/server_name`.
- `terraform/modules/rolesanywhere/main.tf` grants `pgbackup` `s3:ListBucket`, `s3:ListBucketMultipartUploads`, `s3:GetBucketLocation` on the bucket, and `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` on its objects.
- `terraform/modules/pod-identity` plus four `terraform/live/cluster/*-pod-identity` units are the Pod Identity pattern. `eks-pod-identity-agent` is an EKS add-on in `terraform/modules/eks/main.tf`.
- AWS Karpenter pools are Graviton only (`gitops/values.yaml:83-91`). Postgres runs on the on-demand pool.
- `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.0` publishes amd64 and arm64 manifests.
- Constitution §4 already makes the pre-teardown backup best-effort for continuously archiving workloads and excludes discrete-snapshot mechanisms. AWS falls under the relaxation once it archives continuously.
- `PERSISTENT_EXCLUDE` is a single unit name passed as one `--filter "!./$PERSISTENT_EXCLUDE"` (`scripts/persistent-up-civo.sh:18`, `scripts/persistent-down.sh:167`). It is `vpc` on Civo.
- AWS storage is `ebs-delete`: after `make down` the only copy of the AWS lab database is the newest EBS snapshot.
- `scripts/lib/persistent-ebs-artifacts.sh` provides `list_retained_volumes` and `list_postgres_snapshots`, both used by `scripts/persistent-down.sh`.

## 4. Design and contracts

**Bucket — one unit per lifecycle directory, one module.**
- Create `terraform/live/persistent/backups` for AWS from `persistent-civo/backups`, same module. Bucket `vk-lab-platform-postgres-backups`, SSM `/<project>/persistent/backups/bucket_name`.
- Leave `persistent-civo/backups` and its SSM paths unchanged. No live Civo bucket is imported, moved or re-planned.
- `PERSISTENT_EXCLUDE` becomes a space-separated list, expanded into one `--filter` per entry in `persistent-up-civo.sh` and `persistent-down.sh`. Civo sets it to `vpc backups`, so it gets no second bucket.
- `scripts/persistent-down.sh`: add `persistent/backups` to the emptiness list and empty the bucket on both providers.

**Identity on AWS.**
- New module `terraform/modules/postgres-backup-pod-identity` and unit `terraform/live/cluster/postgres-backup-pod-identity`, the same shape as `external-dns-pod-identity`. Service account `cnpg-system/lab-postgres`, the one CNPG creates for the Cluster. Policy: the same S3 actions as the Civo `pgbackup` role, on the literal bucket ARN — no dependency on the persistent layer.
- The association is created by `make up` before `argo-up`, so it exists before the instance pod is admitted.
- `ObjectStore` keeps `s3Credentials.inheritFromIAMRole: true` on both providers.

**GitOps.**
- Move `barman-plugin-application.yaml`, `objectstore.yaml` and `scheduled-backup.yaml` to `gitops/templates/platform/shared/postgres/`, gated on `postgres.backup.enabled` and `target != local`. `aws-config.yaml` and the Cluster's `projectedVolumeTemplate` and `env` stay Civo-only.
- Sidecar image per target: `postgres.backup.sidecarImage` in `gitops/values.yaml` becomes the upstream multi-arch index digest; the Civo custom image moves to a civo-only override passed by `civo_install_root_application`.
- `cluster.yaml`: the `plugins` block and the `externalClusters` recovery branch render for both targets when `postgres.backup.enabled`. The `volumeSnapshot` backup block and the snapshot recovery branch are deleted. The recovery branch keeps no `initdb` fallback.
- Pin `imageName` to one PostgreSQL image by digest in `gitops/values.yaml`, used by both targets, so the operator chart version no longer decides the major.
- `postgres.backup.enabled` becomes `true` for aws in `gitops/values.yaml` and the bootstrap parameters.
- Delete `aws/postgres/recovered-snapshot.yaml`, `aws/ebs-csi/{snapshot-controller,volumesnapshotclass}.yaml`, the `VolumeSnapshotContent` `ignoreDifferences` entry, and `postgres.recoverySnapshotHandle` everywhere.
- Update comments that point at `external-snapshotter-crds` for wave ordering (for example the cert-manager Application).

**Scripts.**
- Rename the `civo_*` backup helpers to provider-neutral names: `backup_publish_server_name`, `backup_prune_generations`, `backup_recovery_handle`, `backup_teardown`, `backup_archiving_status`. Both providers call them.
- Paths stay per provider layer: AWS uses `/<project>/persistent/{backups/bucket_name,postgres-backup/server_name}`, Civo keeps `/<project>/persistent-civo/...`. The helpers take the layer name; there is no pointer migration.
- `argo-up.sh`: delete `aws_resolve_snapshot` and `SNAPSHOT_TAG_FILTERS`. `aws_install_root_application` gains the bucket, `serverName` and `recoverServerName` parameters.
- `argo-down.sh`: delete `aws_cnpg_backup_and_prune`; both providers call `backup_teardown`, which is best-effort under constitution §4.
- `persistent-down.sh`: keep `list_postgres_snapshots` and snapshot deletion, so snapshots left from before this change are still cleaned up; delete the pointer on both providers.

**Documents.**
- ADR 0033 supersedes ADR 0013: one mechanism, PITR on AWS, why Pod Identity is enough, why cross-provider restore is out.
- Constitution §4: replace the ADR 0032 reference with "ADR 0032, ADR 0033"; no rule change.
- `docs/architecture.md`, `docs/aws-platform-design.md`, `tests/manual/007-postgres.md`, `.github/workflows/lifecycle-test.yml` comments: remove snapshot recovery wording.

## 5. Files/components affected

- Terraform: `terraform/live/persistent/backups/` (new), `terraform/modules/postgres-backup-pod-identity/` (new), `terraform/live/cluster/postgres-backup-pod-identity/` (new).
- GitOps: `gitops/templates/platform/shared/postgres/{cluster,barman-plugin-application,objectstore,scheduled-backup}.yaml`, `gitops/templates/platform/civo/postgres/` (only `aws-config.yaml` left), `gitops/templates/platform/aws/postgres/` and `aws/ebs-csi/{snapshot-controller,volumesnapshotclass}.yaml` (removed), `gitops/values.yaml`, `gitops/bootstrap/{values.yaml,templates/root-application.yaml}`.
- Scripts: `scripts/persistent-up-civo.sh`, `scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`, `scripts/persistent-down.sh`, `scripts/gitops-render-check.sh`.
- Tests: `tests/golden/gitops-{aws,civo}/**` regenerated deliberately; `tests/manual/007-postgres.md`.
- Docs: `docs/adr/0033-*.md` (new), `docs/adr/0013-*.md` (status line), `specs/shared/000-D-constitution/spec.md` §4, `docs/architecture.md`, `docs/aws-platform-design.md`, `specs/civo/decisions.md`.

## 6. Implementation steps

1. **Spike gate A — Pod Identity reaches the sidecar.** On a live EKS cluster, hand-apply the pod identity unit, the plugin, the `ObjectStore` and the Cluster `plugins` block. Pass: the `plugin-barman-cloud` init container spec carries `AWS_CONTAINER_CREDENTIALS_FULL_URI` and the token mount, and `ContinuousArchiving=True`. Fallback if the webhook skips the native sidecar: set the two Pod Identity variables and the projected token volume on `Cluster.spec.env` and `projectedVolumeTemplate`, which the sidecar inherits, and record the deviation.
2. **Spike gate B — arm64.** Same cluster: a completed `Backup`, WAL in S3, then a second Cluster recovered from it on an on-demand Graviton node with matching row counts. Record sidecar memory during the base backup.
3. Do not continue unless both gates pass. Record the evidence in §14.

The next steps are ordered so that no AWS bring-up takes the `initdb` branch over real data. Snapshot recovery stays in place until an S3 generation exists.

4. **Additive half.** `PERSISTENT_EXCLUDE` list support, the AWS `persistent/backups` unit, the pod identity unit, the template move, the `imageName` pin, the per-target sidecar image, and provider-neutral script helpers. On AWS the Cluster keeps the snapshot recovery branch, and gains the `plugins` block. `aws_resolve_snapshot` stays. Regenerate goldens and review.
5. **Dual cycle on AWS.** `make up` on the additive code: data comes back from the newest EBS snapshot. Confirm `ContinuousArchiving=True`, a completed `Backup` and the pointer written. Write rows, then one final row, then `make down`: both the teardown snapshot and the S3 archive are taken.
6. **Removal half.** Delete `aws_resolve_snapshot`, `aws_cnpg_backup_and_prune`, `recovered-snapshot.yaml`, the snapshot controller and class, the `ignoreDifferences` entry and `postgres.recoverySnapshotHandle`. The AWS recovery branch is now the plugin branch. Regenerate goldens in a separate commit.
7. Documents: ADR 0033, ADR 0013 status, constitution §4 reference, architecture and AWS design, `specs/civo/decisions.md`.
8. **AWS cycle 1 (plugin only).** `make up` recovers from the step-5 generation. Every row is present, including the final one; archiving goes to a new prefix. Write a new final row, `make down`.
9. **AWS cycle 2.** `make up` recovers from the cycle-1 generation, which was itself a recovered cluster. Confirm the `.history` file and a third prefix.
10. **Civo cycle.** `PROVIDER=civo make down` and `make up` on the final code. Rows match; the Civo bucket and pointer paths are unchanged.

## 7. Dependencies and blockers

CIVO-120 and CIVO-180 proved the plugin, the generation pointer and the
best-effort teardown on Civo. No blocker. Gates A and B in §6 are the
decision points.

## 8. Acceptance criteria

- No bring-up during this spec takes the `initdb` branch, except a deliberate one on an empty database.
- Two AWS down/up cycles on the plugin alone restore every row, including one written seconds before teardown, and each bring-up archives into a new generation prefix.
- One Civo down/up cycle after the change restores every row; `persistent-civo` shows no Terraform change.
- No reference to `VolumeSnapshot`, `recoverySnapshotHandle`, `snapshot-controller` or `external-snapshotter` remains in `gitops/`, `scripts/argo-up.sh`, `scripts/argo-down.sh` or the goldens.
- `persistent-down` still deletes any Postgres EBS snapshot left from before the change.
- Both targets render the same pinned PostgreSQL image.
- No AWS access key exists in the cluster, in SSM or in Git: `grep -rniE 'AKIA[0-9A-Z]{16}'` finds nothing.
- The golden diff contains only the intended additions and removals, reviewed line by line.

## 9. Validation

Offline: `make gitops-check`, `terraform fmt -recursive -check`,
`terragrunt validate`, `bash -n` and `shellcheck` on changed scripts. The
repository has no PR-triggered CI; run these locally.

Real cloud: the spike cluster, three AWS cycles and one Civo cycle, with
`AWS_PROFILE=viacheslav-dev`.

## 10. AWS regression protection

This spec is the AWS change, so protection is proof, not absence of
change: the dual cycle and the two plugin-only AWS cycles in §6. The EBS snapshots that exist before the
change remain until `persistent-down`, so reverting the commit restores
the snapshot path with a snapshot to recover from.

## 11. Rollout and rollback/recovery

Rollback before step 6: revert; snapshot recovery was never removed, and
step 5's teardown snapshot holds the latest rows. Rollback after step 6:
revert, and the restored `aws_resolve_snapshot` finds the step-5 snapshot.
Rows written only after step 5 exist only in S3 and are lost on that path;
state this before reverting. The AWS bucket is additive and can stay.

## 12. Risks and unresolved questions

- **Pod Identity in a native sidecar** is unproven. Gate A decides it, and names the fallback.
- **arm64 physical backup** is unproven in this repository. Gate B decides it.
- **Cutover data loss.** Removing snapshot discovery before an S3 generation exists would make the next bring-up run `initdb` over the lab database. The step 4–6 order is the guard.
- **Recovery time** grows with database size and WAL volume, unlike a snapshot restore. Measure on cycle 1 and adjust `ARGO_UP_WATCH_SECONDS` if needed.
- **Memory on on-demand nodes.** The sidecar adds up to its limit on the Postgres pod. Size from gate B.
- **Wildcard secrets Role** from the plugin (CIVO-180 §12) now exists on AWS too; CIVO-205 covers both.

## 13. Definition of done

- [x] Gates A and B recorded
- [x] Additive half: exclude list, AWS bucket unit, pod identity unit, shared templates, image pin, neutral helpers
- [x] Dual cycle on AWS with both mechanisms live
- [x] Removal half: snapshot surface removed, goldens regenerated and reviewed
- [x] ADR 0033, ADR 0013 status, constitution §4 reference, architecture and AWS design updated
- [ ] Two AWS cycles and one Civo cycle with data evidence
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as READY after the user chose one shared backup mechanism for both providers.
- 2026-09-16 — returned to DRAFT: the body assumed CIVO-180's withdrawn logical-dump design.
- 2026-09-16 — rewritten for the barman-cloud plugin with EKS Pod Identity and promoted to READY. The operator chose to build it before the remaining M1 specs. CIVO-186 (cross-provider promotion) was removed in the same change: separate per-project buckets, the rejected shared bucket, and the arm64/x86_64 split make it a poor fit, and the operator does not expect to use it.
- 2026-09-17 — **Phase A (foundations, PR #14) and spike gates A and B passed** on a live `vk-lab-platform` EKS cluster built from scratch (`make state-up`, `make full-up`; the AWS project had been fully torn down, so no pre-existing lab data existed).
  - Foundations: `PERSISTENT_EXCLUDE` list (Civo `vpc backups`), `persistent/backups` unit (module gains `ssm_layer`, default `persistent-civo`; the live Civo unit plans `No changes.`), `postgres-backup-pod-identity` unit. `make full-up` created bucket `vk-lab-platform-postgres-backups`, SSM `/vk-lab-platform/persistent/backups/bucket_name`, and the `cnpg-system/lab-postgres` association.
  - Snapshot-path baseline before the spike, at the operator's request: table `civo185_proof` with 6 `cycle0` rows; `make down`/`make up` recovered from `snap-088e8c9c9f5528875` with all 6 rows. Then 5 `cycle1` rows, an `UPDATE` of id 3 and a new table `civo185_cycle1_ddl`; `make down`/`make up` recovered from `snap-0ecba2750d5e2440a` with all 11 rows, the update and the table. PostgreSQL is `180004` (18.4), matching the planned `imageName` pin.
  - Gate A: plugin chart 0.8.0 installed by hand with the upstream sidecar `v0.15.0@sha256:06c78dec…`, root auto-sync off, `ObjectStore` applied, Cluster patched with `plugins` only (no `env`). The native sidecar `plugin-barman-cloud` (`restartPolicy: Always`) carried `AWS_STS_REGIONAL_ENDPOINTS`, `AWS_DEFAULT_REGION`, `AWS_REGION`, `AWS_CONTAINER_CREDENTIALS_FULL_URI=http://169.254.170.23/v1/credentials`, `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` and the `/var/run/secrets/pods.eks.amazonaws.com/serviceaccount` mount, injected by the EKS webhook — identical to external-dns. `ContinuousArchiving=True`; WAL under `lab-postgres-spike-20260917T131309Z/wals/`. `pg_stat_archiver.failed_count=6`, all at 13:13:14 UTC during the roll before the sidecar existed; segment 05 archived at 13:13:33. No fallback needed. **Plan deviation D3 (region env on AWS) is unnecessary**: Pod Identity injects both region variables.
  - Coexistence: a `method: plugin` Backup completed in 14 s, then a `method: volumeSnapshot` Backup on the same Cluster completed in 94 s; afterwards the Cluster was healthy and `ContinuousArchiving=True`. Base backup `20260917T131415`. Sidecar peak observed 15Mi on this small database.
  - Gate B: a `gate-b` row written after the base backup, `pg_switch_wal()`, segment `0A` archived. Cluster `spike-restore` (pinned image, on-demand pool, temporary Pod Identity association for its own service account) recovered from the spike `serverName` on `t4g.medium`, `kubernetes.io/arch=arm64`, healthy in 67 s. Row counts matched the source exactly (`cycle0:6 cycle1:5 gate-b:1`, updated id 3, `civo185_cycle1_ddl`), so WAL replay past the base backup works on arm64; the restore promoted to timeline 2. `spike-restore` and the temporary association were deleted.
  - Operational findings, not defects in this spec: (1) parallel sessions share `~/.kube/config`, and a Civo `make kubeconfig` switched `current-context` mid-`argo-down`, which then failed closed on a completed backup; runs now export a per-session `KUBECONFIG`. (2) An IPv6 provider download from the HashiCorp CDN hung `cluster-down` for 30 min; a retry succeeded. (3) A host memory kill stopped `make up` during `terraform init`, before any resource was created; `TG_PARALLELISM=2` was used afterwards. (4) `argocd-repo-server` was OOMKilled once at its 320Mi limit on the first bring-up; root's retry covered it.
- 2026-09-17 — **Phase B (additive half) built and the dual cycle passed** on branch `civo-185-additive`, with `TARGET_REVISION=civo-185-additive` and a per-session `KUBECONFIG`. The AWS project was brought up from scratch again after Phase A's `make full-down`.
  - Code: plugin Application, `ObjectStore` and `ScheduledBackup` moved to `shared/`; sidecar image per target (`postgres.backup.sidecarImages.{aws,civo}`); `Cluster.spec.imageName` pinned to `18.4-system-trixie@sha256:42708a75…`; provider-neutral `backup_*` helpers with `BACKUP_SSM_LAYER`; `aws_install_root_application` passes the backup values; `argo-down` runs the plugin backup, then the aws volume-snapshot backup. The render check gained aws backup renders and asserts the backup objects, the per-target sidecar repository and the pinned image on aws and civo. The civo render differs from `main` only by `imageName`, comments and template source paths.
  - Deviations: D3 (region env on aws) dropped — Gate A showed Pod Identity injects both region variables. D5: `externalClusters` does not render on the aws snapshot-recovery path, which has no consumer for it. D6: aws `make up` now requires `persistent/backups` (fail-hard SSM read).
  - First bring-up (`make full-up`, no snapshot, no pointer): `initdb`; the plugin Application synced from the repo templates; `ContinuousArchiving=True`; the `immediate` ScheduledBackup completed; `lab-postgres-20260917T150154Z/base/…/backup.info` `status=DONE`, `version=180004`; pointer published. Rows `dual-1`, `dual-2`, then `FINAL-DUAL` at 15:13:36 UTC.
  - `make down`: WAL switch, plugin Backup `completed` (~20 s, no warning), then the cold volume-snapshot Backup `completed`; no leaked resources. Generation 1 holds a second `status=DONE` base backup ending 15:14:38 UTC.
  - `make up`: recovered from `snap-0209f45a508d7427e` (`bootstrap.recovery.volumeSnapshots`) with the generation-1 pointer set; the Cluster was admitted with `externalClusters: null`. All three rows present. Archiving into generation 2 `lab-postgres-20260917T155045Z`, whose immediate base backup is `status=DONE`; pointer updated; `2 backup generation(s) stored, keeping 2 - nothing to prune`.
- 2026-09-17 — **Phase C (removal half) built; two AWS cycles on the plugin alone passed** on branch `civo-185-removal` (`TARGET_REVISION=civo-185-removal`).
  - Code: snapshot manifests, CRDs and class, the Cluster snapshot branch and cold backup block, `postgres.recoverySnapshotHandle`, `storage.snapshotClassName`, the root parameter and `ignoreDifferences` entry, `aws_resolve_snapshot`, `aws_cnpg_backup_and_prune` and their tag filters removed. The `ebs-csi` `csi-snapshotter` sidecar was forced on and would crash-loop without the CRDs, so it was removed too. The render check asserts no aws render carries a snapshot object, an external-snapshotter Application or root snapshot settings; goldens: 2443 lines deleted, 15 added (reworded comments). ADR 0033 written; ADR 0013 superseded.
  - Before the cycles, PR #15's code ran `make down` on the dual-cycle cluster: plugin backup and snapshot backup both completed.
  - Cycle 1 `make up`: no snapshot lookup in `argo-up`; `bootstrap.recovery.source: lab-postgres-previous` from generation 2 `lab-postgres-20260917T155045Z`; `dual-1`, `dual-2`, `FINAL-DUAL` present; timeline 2; archiving into generation 3 `lab-postgres-20260917T164746Z` with a `status=DONE` base backup; generation 1 pruned. Rows `row c1` and `FINAL-C1` written at 16:59:15 UTC. `make down`: WAL switch and plugin backup completed, no volume-snapshot step, no leaks; tagged EBS snapshots stayed at 2.
  - Cycle 2 `make up`: recovered from generation 3 (itself a recovered cluster); all five rows including `FINAL-C1`; timeline 3 with `00000003.history.gz` in generation 4 `lab-postgres-20260917T173429Z`; base backup `status=DONE`, `timeline=3`; generation 2 pruned, two generations kept; EBS snapshots still 2; zero snapshot lines in the `argo-up` log.
