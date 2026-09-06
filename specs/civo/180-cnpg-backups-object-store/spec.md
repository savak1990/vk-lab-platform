---
id: "CIVO-180"
title: "Shared logical backup and restore jobs with an S3 bucket"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "A container image, a CronJob, a bucket and two IAM policies; the credential path is already decided"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-082", "CIVO-085", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-180 — Shared logical backup and restore jobs

## 1. Outcome and rationale

A daily `CronJob` dumps the PostgreSQL database and uploads it to an S3
bucket. A restore `Job` loads the newest dump into an empty database.
Both run from one image that this repository builds. The same manifests
work on AWS and on Civo, because the only difference is how the pod
obtains AWS credentials.

The Civo CSI driver cannot snapshot or clone volumes, so the AWS
snapshot flow (ADR 0013) cannot be mirrored. Logical dumps to S3 cost
about 0.25 USD per month, need no permanent credential, and give one
mechanism for both providers.

## 2. Scope and non-goals

In scope:
- An S3 bucket in the AWS persistent stack, with a lifecycle rule that expires old dumps.
- One container image with `pg_dump`, `psql`, `pg_restore`, the AWS CLI and `aws_signing_helper`.
- A `CronJob` for the daily dump and a `Job` template for restore.
- IAM for both providers: a Pod Identity role on AWS and a Roles Anywhere role on Civo.
- Verification on Civo, including one dump and one restore.

Not in scope:
- The CNPG `Cluster` on Civo and the two-cycle data proof (CIVO-120).
- Switching the AWS target off EBS snapshots (CIVO-185).
- Point-in-time recovery. Logical dumps restore to the moment of the dump.

## 3. Current state / evidence

- CNPG on AWS backs up with `Backup method: volumeSnapshot` to EBS, driven by `scripts/argo-down.sh:54-113` and `scripts/argo-up.sh:167-197`.
- `csi.civo.com` advertises no snapshot or clone capability, so neither snapshots nor CNPG's PVC-datasource recovery work on Civo. See `research.md`.
- The database password already reaches the cluster as Secret `lab-postgres-app` through External Secrets.
- CIVO-085 issues short-lived certificates from the project CA. CIVO-082 creates one Roles Anywhere role for each consumer.
- The credential helper supports `credential-process`, which the AWS CLI reads from an AWS config file. A pod that owns its image needs no sidecar.

## 4. Design and contracts

- Bucket: `terraform/live/persistent/backups` creates `${project}-backups` with SSE-S3, a full public access block, and a lifecycle rule that expires objects under `postgres/` after 14 days. Lifecycle class persistent. The bucket serves both providers of that project.
- Image `images/pg-backup`: a Debian base with the PostgreSQL client matching the server major version, the AWS CLI, and the pinned `aws_signing_helper` binary. It runs as a non-root user.
- Credentials on AWS: a Pod Identity association binds the ServiceAccount `postgres-backup` in `cnpg-system` to a role that allows `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` and `s3:DeleteObject` on `${project}-backups/postgres/*`. The AWS CLI uses the default chain and needs no configuration.
- Credentials on Civo: the pod mounts the certificate Secret `pgbackup-ra-cert` and an AWS config file from a ConfigMap. The config file sets `credential_process = /usr/local/bin/aws_signing_helper credential-process ...` with the trust anchor, profile and role ARNs from values. `AWS_CONFIG_FILE` points at the mount. No sidecar runs, so the Job terminates cleanly.
- `CronJob postgres-backup` in `cnpg-system`, schedule `0 3 * * *`, `concurrencyPolicy: Forbid`, `backoffLimit: 2`. It runs `pg_dump --format=custom --no-owner --no-privileges` and pipes the output to `aws s3 cp - s3://${bucket}/postgres/${cluster}-$(date -u +%Y%m%dT%H%M%SZ).dump`.
- Teardown: `argo-down` creates a one-off Job from the CronJob with `kubectl create job --from=cronjob/postgres-backup`, then waits with `kubectl wait --for=condition=complete --timeout=600s`. A failure or a timeout exits non-zero and leaves the cluster running, unless `CI_TEARDOWN_ALLOW_DATA_LOSS=1` is set.
- Restore: a `Job postgres-restore` carries the Argo hook `PostSync` on the Postgres Application. It counts tables in the target schema. When the count is zero and a dump exists, it downloads the newest object and runs `pg_restore`. When the count is not zero it exits successfully without touching data. This makes the restore idempotent across re-syncs.
- Values: `postgres.backup.enabled`, `postgres.backup.bucket`, `postgres.backup.schedule`, `postgres.backup.retentionDays`, `awsIdentity.mode` selects the credential path.

## 5. Files/components affected

- `terraform/live/persistent/backups/terragrunt.hcl` and `terraform/modules/s3-backups` (new).
- `terraform/modules/pg-backup-pod-identity` (new, AWS) and the `pgbackup` consumer in `terraform/modules/rolesanywhere` (CIVO-082 variable list).
- `images/pg-backup/Dockerfile` and a build workflow (new).
- `gitops/templates/platform/shared/postgres/backup-cronjob.yaml` and `restore-job.yaml` (new).
- `gitops/templates/platform/civo/postgres/aws-config.yaml` (ConfigMap, new).
- `scripts/argo-down.sh` (teardown job gate), `gitops/values.yaml`.

## 6. Implementation steps

1. Add the bucket module and unit. Apply with `make persistent-up` for the Civo project.
2. Add the `pgbackup` consumer to the Roles Anywhere module and re-apply the bootstrap unit.
3. Add the certificate for `pgbackup` to CIVO-085's list.
4. Build and push the image. Pin it by digest in values.
5. Add the CronJob, the restore Job and the ConfigMap. Run `make gitops-check`; the AWS golden diff must stay empty while `postgres.backup.enabled` is false on AWS.
6. On Civo, run the CronJob once by hand. Confirm the object appears in S3.
7. Drop the database contents in a scratch copy and run the restore Job. Confirm the row counts match.
8. Add the teardown gate to `argo-down` and confirm it fails closed when the job fails.

## 7. Dependencies and blockers

CIVO-082 supplies the role, CIVO-085 the certificate, CIVO-100 the database password. CIVO-120 consumes this spec.

## 8. Acceptance criteria

- A dump lands in S3 from a Civo pod using temporary credentials only. `aws sts get-caller-identity` inside the pod returns the `pgbackup` role.
- The restore Job loads a dump into an empty database and exits successfully without changes when the database already has tables.
- The lifecycle rule removes dumps older than 14 days.
- The teardown gate fails closed on a failed dump.
- No permanent AWS key exists anywhere in the repository, the cluster or SSM.
- The AWS golden diff is empty.

## 9. Validation

Offline: `docker build`, `helm template`, the golden diff. Real cloud:
one Civo cluster, one bucket. Storage cost about 0.25 USD per month.
Request cost is negligible at one dump per day.

## 10. AWS regression protection

The AWS target keeps EBS snapshots until CIVO-185. The new manifests
render only when `postgres.backup.enabled` is true, which stays false on
AWS in this spec. The golden diff proves it.

## 11. Rollout and rollback/recovery

Revert the manifests to stop backing up. The bucket and its contents
survive, because it belongs to the persistent stack. `persistent-down`
empties and deletes it after a confirmation.

## 12. Risks and unresolved questions

- The dump duration for 20 GiB sets the teardown timeout. Measure once and adjust.
- `pg_dump` and the server major version must match. Pin the image to the CNPG image's major version.
- A logical dump restores to the moment of the dump. Anything written after the last dump and before a teardown failure is lost. The teardown gate exists precisely to bound that window.

## 13. Definition of done

- [ ] Bucket, image, CronJob, restore Job and IAM in place
- [ ] Dump and restore verified on Civo with evidence
- [ ] Teardown gate verified
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT (Civo Object Store and barman plugin).
- 2026-09-06 — user decision: replaced the Civo Object Store and barman-cloud design with shared logical dumps to S3. The Civo Object Store bills for a 500 GB minimum, about 5.43 USD per month, while S3 bills for bytes stored, about 0.25 USD per month. Logical dumps also avoid a permanent AWS key, because this repository owns the job image and can use `credential-process`.
