---
id: "CIVO-180"
title: "CNPG barman-cloud plugin backups to a per-project S3 bucket"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "A sidecar image, a bucket, an IAM policy and a CNPG-I plugin; the credential path runs inside a distroless container this repo does not control the entrypoint of"
effort_estimate: "Two sessions (8–12 h) including a spike against a live cluster"
estimate_confidence: "medium"
depends_on: ["CIVO-082", "CIVO-085", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-16"
completed: "2026-09-16"
---

# CIVO-180 — Barman-cloud plugin backups to S3

## 1. Outcome and rationale

CloudNativePG archives WAL continuously and takes scheduled base backups
into a per-project S3 bucket, through the **barman-cloud CNPG-I plugin**.
The plugin injects a sidecar into each instance pod; this repository
builds that sidecar's image, adding one binary — `aws_signing_helper` —
so the sidecar reaches S3 with IAM Roles Anywhere and no AWS key at rest.

The Civo CSI driver advertises no snapshot and no clone capability, so
the AWS `VolumeSnapshot` flow (ADR 0013) has no Civo equivalent. ADR 0031
first chose logical `pg_dump` files on the premise that CNPG offers no
supported way to add a container to its instance pods. **That premise is
false**, and ADR 0032 reverses it. Physical backups cost about the same
(~0.25 USD per month of S3), need no permanent credential, and keep
point-in-time recovery, which logical dumps would have surrendered.

S3 rather than a Civo bucket: Civo Object Store bills a 500 GB minimum,
about 5.43 USD per month. S3 bills bytes stored.

## 2. Scope and non-goals

In scope:
- An S3 bucket in the **Civo** persistent stack, with a backstop lifecycle rule.
- A `pgbackup` Roles Anywhere consumer with a least-privilege S3 policy.
- One container image: the upstream plugin sidecar plus `aws_signing_helper`, and a workflow that builds and publishes it.
- The plugin Application, the `ObjectStore`, the credential `ConfigMap` and the `ScheduledBackup`.
- A spike proving the credential path works before any of it is committed.

Not in scope:
- The CNPG `Cluster` wiring and the two-cycle data proof (CIVO-120).
- Switching the AWS target to the same mechanism (CIVO-185, which now needs a redesign).
- The AWS target's EBS snapshots, which are untouched.

## 3. Current state / evidence

- CNPG on AWS backs up with `Backup method: volumeSnapshot` to EBS, driven by `scripts/argo-down.sh` and `scripts/argo-up.sh`.
- `csi.civo.com` advertises no snapshot or clone capability, so neither snapshots nor CNPG's PVC-datasource recovery work on Civo. See `research.md`.
- `plugin-barman-cloud` v0.15.0, `internal/cnpgi/operator/lifecycle.go`, copies the `postgres` container's volume mounts onto its own sidecar: `sidecar.VolumeMounts = ensureVolumeMount(sidecar.VolumeMounts, spec.Containers[i].VolumeMounts...)`. This is the fact the whole design rests on.
- `Cluster.spec.projectedVolumeTemplate` mounts arbitrary Secrets and ConfigMaps into instance pods at `/projected`.
- CIVO-085 issues short-lived certificates from the project CA. CIVO-082 creates one Roles Anywhere role for each consumer.

## 4. Design and contracts

- **Bucket.** `terraform/live/persistent-civo/backups` creates `${project}-postgres-backups` with SSE-S3, `bucket_key_enabled`, a full public access block, a `DenyInsecureTransport` bucket policy and `force_destroy = false`. Versioning off. One lifecycle rule as a **backstop only**: expire objects after 30 days, abort incomplete multipart uploads after 7. It is set well above any retention window on purpose — an aggressive rule would delete WAL segments that a surviving base backup still needs. The unit lives in `persistent-civo`, not `persistent`: the latter applies on both providers and would create an AWS bucket. Publishes SSM `/${project}/persistent-civo/backups/bucket_name` as `String`.
- **IAM.** `pgbackup` joins the hardcoded consumer map in `terraform/modules/rolesanywhere`, which creates role `${project}-ra-pgbackup`, adds it to the shared profile, publishes its ARN to SSM and builds a trust policy conditioned on the certificate common name `${project}-civo-pgbackup`. The policy grants, on the bucket: `s3:ListBucket`, `s3:ListBucketMultipartUploads`, `s3:GetBucketLocation`; on `${bucket}/*`: `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`. The multipart actions are what make a large base backup work. The bucket ARN is a literal string, not a data source — `bootstrap` applies before `persistent-civo`.
- **Image.** `images/cnpg-barman-sidecar/Dockerfile` is the upstream sidecar pinned by digest, plus `aws_signing_helper` copied in from a builder stage and verified with `sha256sum -c`. `ENTRYPOINT`, `USER 26:26` and `PATH` are inherited unchanged. The base is distroless with no shell, so there is no wrapper script and no supervisor.
- **Credentials: `credential_process`, no wrapper and no background process.** ConfigMap `pgbackup-aws-config` holds an AWS profile whose `credential_process` invokes `aws_signing_helper credential-process` against the mounted certificate. `AWS_CONFIG_FILE` points at it. botocore spawns the helper fresh on each credential fetch, so it always reads the **current** certificate file and cert-manager rotation needs no restart. A `serve` listener would instead need a static-binary entrypoint, and a crashlooping entrypoint would block the Postgres pod entirely, because the sidecar is a native sidecar — an initContainer with `restartPolicy: Always`.
- **Registry: GHCR, as a public package.** ECR private would need the cluster to authenticate on every pull with a 12-hour token, which means a permanent credential in an `imagePullSecret` — exactly what this design exists to avoid. ECR Public would cost an ADR 0024 exception for a `us-east-1` provider alias. GHCR needs neither: the repository is public and the push authenticates with the built-in `GITHUB_TOKEN`. **The package must be made public by hand on first push**; there is no `imagePullSecret` anywhere in this repository, so a private package means `ImagePullBackOff`.
- **Build shape.** A separate workflow, `.github/workflows/sidecar-image.yml`, triggered on `paths: images/**` plus `workflow_dispatch`, with `permissions: {contents: read, packages: write}`. It stays out of `lab.yml` and `lifecycle-test.yml`: those hold `id-token: write` and AWS credentials, and the image is a pinned dependency rather than a per-run artifact. Building it inside the lifecycle test would either override the committed digest — so the cluster runs something `main` does not declare — or build and discard the result.
- **Plugin Application**, sync wave 1: after cert-manager at wave 0, which the plugin needs for its own serving certificate, and before the Cluster at wave 3. Destination namespace `cnpg-system`; the plugin must live in the operator's namespace. The chart composes `registry/repository:tag`, so the digest is pinned as `tag@digest`, which renders a valid reference that resolves by digest — no `SIDECAR_IMAGE` override is needed.
- **`ObjectStore lab-postgres-backups`**, wave 2, with `SkipDryRunOnMissingResource=true` because its CRD arrives with the wave-1 Application. `destinationPath: s3://<bucket>/`, `wal.compression: gzip`, `data.compression: gzip`, `retentionPolicy: "2d"`, and **`s3Credentials.inheritFromIAMRole: true`** — mandatory. Any other setting makes `barman-cloud/pkg/credentials/env.go` append `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which win through Go's `os/exec` last-wins rule; omitting credentials entirely is rejected with `no credentials defined`.
- **`ScheduledBackup`**, wave 4: `schedule: "0 0 3 * * *"` (CNPG uses a six-field, seconds-first spec), `immediate: true`, `backupOwnerReference: self`, `method: plugin`. `immediate: true` is what makes it useful at all on a cluster that may live less than a day.
- **Retention is a recovery window, not a count.** `retentionPolicy` matches `^[1-9][0-9]*[dwm]$`, and it prunes only from inside a live cluster, scoped to that cluster's own `serverName`. Bounding the number of stored generations is `argo-up`'s job and belongs to CIVO-120.
- **`civoIdentity.consumers`** gains `{name: pgbackup, namespace: cnpg-system}`, which produces Secret `pgbackup-ra-cert` at wave 1 with the matching common name.

## 5. Files/components affected

- `terraform/modules/postgres-backups/{main,variables,outputs,versions}.tf` and `terraform/live/persistent-civo/backups/terragrunt.hcl` (new).
- The `pgbackup` consumer and its policy document in `terraform/modules/rolesanywhere/main.tf`.
- `images/cnpg-barman-sidecar/Dockerfile` and `.github/workflows/sidecar-image.yml` (new).
- `gitops/templates/platform/civo/postgres/{barman-plugin-application,objectstore,aws-config,scheduled-backup}.yaml` (new).
- `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`, `scripts/gitops-render-check.sh`.

## 6. Implementation steps

1. Add the bucket module and unit, and the `pgbackup` consumer. Apply the bootstrap and `persistent-civo` stacks.
2. Add the image and its workflow. Merge to `main`, which fires the build on its own.
3. **Make the GHCR package public**, then prove it pulls from the cluster, not only from a workstation.
4. **Spike against a live cluster before committing any manifest.** Install the plugin by hand, hand-write the `Certificate` with a deliberately short lifetime, and patch the Cluster. Four gates: the mount reaches the sidecar; S3 works with no AWS key; rotation is survived; the generated RBAC applies. Record the sidecar's RSS during a base backup to size its resources.
5. Add the plugin Application, the `ObjectStore`, the ConfigMap and the `ScheduledBackup`. Extend the render check.
6. Hand the Cluster wiring and the cycle proof to CIVO-120.

## 7. Dependencies and blockers

CIVO-082 supplies the role, CIVO-085 the certificate, CIVO-100 the
database password. CIVO-120 consumes this spec.

## 8. Acceptance criteria

- WAL is archived to S3 from a Civo pod using temporary credentials only, with **no AWS key present anywhere** — not in the image, not in the cluster, not in SSM.
- The projected mount is inherited by the plugin's sidecar. It is the only route a file has into that container, which exposes no `volumeMounts` field of its own.
- Certificate rotation is survived, judged against the `notAfter` of the certificate present at pod start, not against elapsed time.
- A `Backup` with `method: plugin` reaches `completed` and its objects land under `base/` and `wals/`.
- The bucket carries SSE-S3, a public access block, a TLS-only policy, the backstop lifecycle rule and the four required tags.
- The `platform` and `platform-recovery` goldens are unchanged; the `bootstrap` golden gains only the new empty-valued Helm parameters.

## 9. Validation

Offline: `terraform fmt -check`, `terragrunt validate`, `docker build`,
`make gitops-check`. This repository has no PR-triggered CI, so these run
locally. Real cloud: one Civo cluster and one bucket. Storage about
0.25 USD per month; request cost negligible.

## 10. AWS regression protection

Every new object renders only on the civo target. The AWS target keeps
EBS snapshots until CIVO-185. The `platform` and `platform-recovery`
golden diffs prove the AWS render is byte-identical.

## 11. Rollout and rollback/recovery

Revert the manifests to stop backing up. The bucket and its contents
survive, because it belongs to the persistent stack. `persistent-down`
empties it and deletes it under the existing `CONFIRM_DESTROY` prompt —
`force_destroy` is false, so an unemptied bucket fails the destroy.

## 12. Risks and unresolved questions

- **The generated plugin RBAC is over-broad.** `Role/lab-postgres-barman-cloud` carries a secrets rule with an **empty** `resourceNames`: `[""] ["secrets"] ["get","watch","list"]`. That is read access to every Secret in `cnpg-system`, including `lab-postgres-app` and `pgbackup-ra-cert`. Upstream issue #892. It applies cleanly here only because this repository runs no restrictive operator RBAC. Carried to CIVO-205.
- The GHCR package is public by a manual step, not by code. A repository re-creation would lose it and produce `ImagePullBackOff` with no obvious cause.
- Memory headroom is tight: about 2308 MiB allocatable per node. The sidecar's footprint during a base backup was measured in the spike rather than guessed.
- The shared Roles Anywhere profile's 3600s session duration is unchanged. It clears botocore's 15-minute refresh threshold four times over, and raising it would raise it for eso, external-dns and cert-manager too.

## 13. Definition of done

- [x] Bucket, `pgbackup` role, sidecar image and build workflow in place
- [x] Plugin Application, `ObjectStore`, credential ConfigMap and `ScheduledBackup` in place
- [x] Spike passed all four gates against a live cluster, with evidence
- [x] Archiving and a completed `Backup` verified on Civo
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT (Civo Object Store and barman plugin).
- 2026-09-06 — user decision: replaced the Civo Object Store and barman-cloud design with shared logical dumps to S3. The Civo Object Store bills for a 500 GB minimum, about 5.43 USD per month, while S3 bills for bytes stored, about 0.25 USD per month. Logical dumps also avoid a permanent AWS key, because this repository owns the job image and can use `credential-process`.

- 2026-09-16 — **decision reversed again, back to the barman-cloud plugin (ADR 0032).** The 2026-09-06 rejection rested on "CNPG has no supported way to add a container of one's own to its managed instance pods". That is false: the plugin injects its own sidecar, `SIDECAR_IMAGE` selects that sidecar's image, and `internal/cnpgi/operator/lifecycle.go` copies the `postgres` container's volume mounts onto it. The cost argument for S3 over Civo Object Store is unaffected and still holds. Point-in-time recovery, surrendered by the logical-dump design, returns.

- 2026-09-16 — **spike passed all four gates against a live Civo cluster.** Bucket `vk-civo-lab-postgres-backups`, role `vk-civo-lab-ra-pgbackup`, CNPG 1.30.0, plugin chart 0.8.0 (app v0.15.0). (a) The `/projected` mount appears on the `plugin-barman-cloud` container. (b) The sidecar carried exactly three AWS variables and no key; `ContinuousArchiving=True`, a `Backup` with `method: plugin` reached `completed`, 65 objects landed. (c) With a 1-hour certificate rotating about every five minutes: 12 rotations, 0 archiving failures across 59 minutes, with five WAL segments written **after** the `notAfter` of the certificate present at pod start. (d) The generated RBAC applied, with the wildcard-secrets finding recorded in §12. Also settled: `tag@digest` pins the image through the chart, and Argo CD v3.5.1 accepts an `oci://` chart source.

- 2026-09-16 — **implementation merged.** PR #7 (`330fd65`) shipped the plugin Application, the `ObjectStore`, the `pgbackup-aws-config` ConfigMap, the `ScheduledBackup`, the values in all three places and the render-check assertions. The Terraform bucket, the `pgbackup` role and the sidecar image landed before it, at Checkpoint A. All seven Applications reached `Synced/Healthy`; `ScheduledBackup` with `immediate: true` produced a `completed` Backup. PRs #8–#11 (`b567ad5`, `5aa0167`, `f86f14c`, `0ef8295`) carried the teardown behavior, ADR 0032 and the generation pruning, which belong to CIVO-120.

- 2026-09-16 — **body rewritten from logical dumps to the shipped design; status `DONE`.** §§1, 2, 4, 5, 6, 8, 10, 11, 12 and 13 described a `pg_dump` image, a daily `CronJob`, a `PostSync` restore Job, an AWS Pod Identity role and a bucket under `persistent/` — none of which exist. §4 was additionally half-edited: its teardown bullet already described the best-effort plugin `Backup` while every other bullet still described dumps. The acceptance criterion *"The teardown gate fails closed on a failed dump"* is deleted; ADR 0032 and constitution §4 make the pre-shutdown backup best-effort. *"The AWS golden diff is empty"* is replaced by the accurate form — the `platform` and `platform-recovery` goldens are unchanged, and the `bootstrap` golden gains only the new empty-valued parameters. The title changed, so `README.md` changed with it.

  Downstream: CIVO-185 expected an AWS Pod Identity role from this spec that was never built, and is returned to `DRAFT` for a redesign onto the plugin. CIVO-186 rested on `pg_dump --no-owner --no-privileges` portability and is `BLOCKED` on that redesign.
