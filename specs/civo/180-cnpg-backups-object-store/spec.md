---
id: "CIVO-180"
title: "Backup bucket, S3 identity on both providers, and the pg-backup image"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "A bucket, two IAM paths that both copy existing modules, and a container image; the credential design is already settled by ADR 0029 and ADR 0031"
effort_estimate: "One session (4–6 h) including one Civo bring-up for the smoke test"
estimate_confidence: "medium"
depends_on: ["CIVO-082", "CIVO-085", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-11"
completed: null
---

# CIVO-180 — Backup bucket, S3 identity, and the pg-backup image

## 1. Outcome and rationale

A pod on Civo reads and writes objects in this project's backup bucket using
temporary credentials only, and the same identity exists on AWS ready for
CIVO-185 to use. The container image that will carry every dump and restore is
built, published and pinned by digest.

This spec delivers the plumbing and proves it. It does not back up a database —
CIVO-120 does that, and it can only do it once the bucket, the identity and the
image exist. Splitting them means the hard part (a Roles Anywhere identity
reaching S3 from outside AWS) is proven on its own, before any data depends on
it.

ADR 0031 already chose logical dumps over CNPG's native object-store backup.
Three facts confirmed against the current upstream code keep that choice sound
and are recorded in §12 rather than re-argued here.

## 2. Scope and non-goals

In scope:
- An S3 bucket per project in the AWS persistent stack, and its name in SSM.
- A `pgbackup` Roles Anywhere consumer (Civo) and a Pod Identity association
  (AWS), with identical S3 permissions.
- A cert-manager `Certificate` issuing `pgbackup-ra-cert`.
- The `images/pg-backup` image and the workflow that publishes it.
- Pinning the CNPG server image so the PostgreSQL major version cannot drift
  away from the client tools in that image.
- One smoke test on a live Civo cluster proving the credential chain reaches S3.

Not in scope:
- Any CNPG backup or restore behaviour, any CronJob, any change to
  `argo-up`/`argo-down` (CIVO-120).
- Enabling any of this on the AWS target (CIVO-185). The AWS IAM is written
  here and applied by the next AWS `cluster-up`, but nothing consumes it.
- Point-in-time recovery. Logical dumps restore to the moment of the dump.
- A daily schedule. Backups are taken at teardown; see CIVO-120 §4.

## 3. Current state / evidence

- There is exactly one bucket-creating module in the repository,
  `terraform/modules/terraform-state`, used by `terraform/live/state` and
  `terraform/live/account-state` for Terraform's own backend. No backup bucket
  exists in any stack.
- `terraform/modules/rolesanywhere/main.tf:14-20` declares consumers as a
  hardcoded `local.consumers` map with three keys — `eso`, `external-dns`,
  `cert-manager` — each mapped to an inline policy document. **There is no
  consumers input variable.** Adding a fourth consumer is an edit to the module
  body, not a change to a caller's inputs. An earlier draft of this spec claimed
  otherwise.
- Each consumer's IAM role is named `${project}-ra-${consumer}` and its trust
  policy pins `aws:PrincipalTag/x509Subject/CN` to `${project}-civo-${consumer}`
  and `x509Issuer/CN` to the project CA. Role ARNs reach the cluster as plain
  `String` SSM parameters under `/${project}/bootstrap/rolesanywhere/`.
- `gitops/templates/platform/civo/identity/certificates.yaml` issues one
  `Certificate` per entry in `.Values.civoIdentity.consumers`
  (`gitops/values.yaml:111-118`), with CN `<project>-civo-<name>`, 24h duration
  and `secretName: <name>-ra-cert`. Adding a consumer is a values edit.
- `terraform/modules/pod-identity` is the shared AWS base; five thin wrappers
  (`external-secrets-pod-identity` and siblings) each add one policy. A sixth
  follows the same shape.
- The repository has never built or published a container image. Every image it
  runs is upstream and pinned by digest, for example the credential helper at
  `gitops/values.yaml:30`.
- The CNPG operator is chart `0.29.0`, app version 1.30.0
  (`gitops/templates/platform/shared/postgres/application.yaml:13-14`). The
  `Cluster` CR sets no `imageName`, so the server runs whatever that operator
  defaults to — PostgreSQL 18.4 today, and something else after a chart bump.

## 4. Design and contracts

- **Bucket.** `terraform/modules/s3-backups` creates `${project}-backups`:
  SSE-S3, `bucket_key_enabled`, a full public access block, the same
  deny-insecure-transport policy `terraform-state` uses, and `force_destroy`
  behind a variable so `persistent-down` can empty it. No versioning — the
  retention contract is "the newest 2 keys", and versioning would hide deleted
  copies from that count. **No lifecycle rule**: S3 lifecycle expiry is
  age-based and cannot express a count.
- **One bucket per project, not one shared bucket.** `PROJECT_NAME` differs per
  provider, so `vk-lab-platform-backups` and `vk-civo-lab-backups` both exist in
  one AWS account. ADR 0031's phrase "a shared S3 bucket" means a shared
  *mechanism*, image and object contract. CIVO-186 depends on there being two.
- **Unit.** `terraform/live/persistent/backups` is applied by
  `make persistent-up` on both providers — the Civo project runs the AWS
  persistent stack already, for SSM. Lifecycle class Persistent: the bucket
  outlives `make down` and is destroyed only by `persistent-down`.
- **Bucket name to the cluster** at `/${project}/persistent/backups/bucket_name`,
  plain `String` (ADR 0023 — a bucket name is not a credential).
- **Object layout.** `postgres/${cluster}-${YYYYMMDDTHHMMSSZ}.dump`, one flat
  prefix. The timestamp is UTC and lexically sortable, which makes "newest key"
  and "newest backup" the same question.
- **Civo identity.** A fourth entry in `local.consumers`, `pgbackup`, with an
  `aws_iam_policy_document.pgbackup` granting `s3:PutObject`, `s3:GetObject`,
  `s3:DeleteObject` on `arn:aws:s3:::${project}-backups/postgres/*` and
  `s3:ListBucket` on the bucket itself, scoped by a `s3:prefix` condition of
  `postgres/`. Its role ARN is exported to
  `/${project}/bootstrap/rolesanywhere/role_arn/pgbackup`.
- **Civo credential path.** The image owns `aws_signing_helper`, so it needs no
  sidecar: an `AWS_CONFIG_FILE` from a ConfigMap sets
  `credential_process = /usr/local/bin/aws_signing_helper credential-process …`
  with the trust anchor, profile and role ARNs from values. This is the
  deviation ADR 0031 explicitly permits from ADR 0029's sidecar pattern, and it
  is the reason a Job created from this image terminates instead of hanging on a
  sidecar that never exits.
- **AWS identity.** `terraform/modules/pg-backup-pod-identity` wraps
  `terraform/modules/pod-identity`, binding ServiceAccount `postgres-backup` in
  `cnpg-system` to a role carrying the same four actions on the same resources.
  Applied by `terraform/live/cluster/pg-backup-pod-identity` on the next AWS
  `cluster-up`. IAM roles and associations are free; nothing consumes this until
  CIVO-185.
- **Image.** `images/pg-backup`, non-root, carrying the PostgreSQL **18** client
  tools (`pg_dump`, `pg_restore`, `psql`), the AWS CLI, and the
  `aws_signing_helper` binary pinned to the same version the sidecar uses.
  Published to GHCR by a workflow triggered on `images/pg-backup/**` and pinned
  by digest in `gitops/values.yaml`. GHCR packages are anonymously pullable, so
  no cluster pull secret is needed.
- **Server image pin.** `Cluster.spec.imageName` is set explicitly. A `pg_dump`
  older than the server refuses to run, and a dump restored into an older server
  fails; leaving the major version to an operator default makes both failures a
  surprise at teardown rather than a decision. This is the one change here that
  alters the AWS golden render.

## 5. Files/components affected

New: `terraform/modules/s3-backups/`, `terraform/live/persistent/backups/`,
`terraform/modules/pg-backup-pod-identity/`,
`terraform/live/cluster/pg-backup-pod-identity/`, `images/pg-backup/`,
`.github/workflows/` image build, and
`gitops/templates/platform/civo/postgres/aws-config.yaml`.

Modified: `terraform/modules/rolesanywhere/{main,outputs}.tf`,
`gitops/values.yaml` (consumer list, image digest, bucket value key),
`gitops/templates/platform/shared/postgres/cluster.yaml` (`imageName`),
`tests/golden/gitops-aws/` (one key, deliberately),
`scripts/gitops-render-check.sh` (`Certificate__cnpg-system__pgbackup`).

## 6. Implementation steps

1. Write the bucket module and unit. `PROVIDER=civo make persistent-up`.
   Confirm the bucket and the SSM parameter.
2. Add the `pgbackup` consumer and its policy to the Roles Anywhere module.
   `PROVIDER=civo make bootstrap-up`. Confirm the role and its SSM parameter.
3. Add `pgbackup`/`cnpg-system` to `civoIdentity.consumers`.
4. Write the `pg-backup` image and its workflow. Build locally first; publish;
   pin by digest.
5. Pin `Cluster.spec.imageName` and regenerate the golden render with
   `MODE=update` — **its own commit**, so a one-key diff is reviewable alone.
6. Add the ConfigMap holding the AWS config file.
7. `PROVIDER=civo make up`. Run the smoke test in §9.

## 7. Dependencies and blockers

CIVO-082 supplies the trust anchor and the module this extends. CIVO-085
supplies the issuer that mints the certificate. CIVO-100 proves the chain works
end to end for a real consumer. Nothing blocks.

## 8. Acceptance criteria

- `${project}-backups` exists for both projects, is not publicly readable, and
  rejects plaintext HTTP.
- From a pod on Civo using only the mounted certificate:
  `aws sts get-caller-identity` returns the `${project}-ra-pgbackup` role, and
  an object round-trips through `aws s3 cp` in both directions.
- That pod cannot read or write outside `postgres/`, and cannot touch the other
  project's bucket. State this as a test, not an intention.
- A certificate carrying the wrong CN is refused by STS.
- No permanent AWS key exists in the repository, the cluster, SSM, or the image.
- The AWS golden diff is empty apart from the deliberate `imageName` commit,
  whose diff is exactly one key on one object.
- `PROVIDER=aws make -n up` output is unchanged.

## 9. Validation

Offline: `terraform fmt`/`validate`, `terragrunt validate`, `shellcheck`,
`docker build`, `make gitops-check`.

Smoke test, on a live Civo cluster: a throwaway pod from the image, mounting
`pgbackup-ra-cert` and the AWS config ConfigMap, running
`aws sts get-caller-identity`, then `aws s3 cp` up and down, then a deliberate
`aws s3 ls` against a forbidden prefix expecting `AccessDenied`.

Real cloud: one short Civo cluster session, well under 1 USD. The bucket itself
is about 0.25 USD per month at the expected volume. No Let's Encrypt production
order is spent — the existing certificate round-trips through SSM.

## 10. AWS regression protection

Every new Kubernetes manifest is Civo-gated or gated on
`postgres.backup.enabled`, which stays false on AWS until CIVO-185. The golden
render is the proof, and it must be empty for every commit in this spec except
step 5's. The new AWS Terraform creates IAM only — no compute, no data path —
and is verified by `terragrunt plan` rather than by an AWS cluster cycle.

## 11. Rollout and rollback/recovery

Data risk: none. Nothing in this spec reads or writes a database. Rollback is
reverting the commits and destroying the bucket, which at this point holds only
the smoke test's object.

## 12. Risks and unresolved questions

- **Publishing an image is new ground for this repository.** The workflow,
  digest pinning and anonymous pull all need proving here. This is the most
  likely place the session overruns.
- **CNPG's native object-store backup was re-evaluated and rejected again**,
  against current upstream code rather than against ADR 0031's summary of it:
  in-tree `barmanObjectStore` is deprecated and removed in CNPG 1.31, one minor
  release past the 1.30.0 this platform runs; the replacement plugin's
  `ObjectStore.spec.instanceSidecarConfiguration` accepts `env`, `resources`,
  `logLevel`, `additionalContainerArgs` and `retentionPolicyIntervalSeconds`
  and nothing else, so there is no way to mount a client certificate or a
  signing binary into the sidecar that would need them; and its
  `retentionPolicy` is recovery-window only (`^[1-9][0-9]*[dwm]$`), so "keep the
  newest two" is not expressible. The plugin controller does expose a global
  `SIDECAR_IMAGE` override, so the second point is escapable by forking and
  maintaining a sidecar image — the third is not. Revisit only if count-based
  retention lands upstream.
- The `aws_signing_helper` version must stay in step with the sidecar's pinned
  digest. Two copies of one binary version is a small drift risk; note it where
  both are pinned.
- Whether a single image can carry both the PostgreSQL 18 client and a current
  AWS CLI without a large size penalty is unmeasured. If it is unpleasant, a
  two-stage build copying only the client binaries is the fallback.

## 13. Definition of done

- [ ] Bucket, both IAM paths, certificate, image and image pin in place
- [ ] Smoke test recorded, including the two negative cases
- [ ] Golden render empty except the deliberate `imageName` commit
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT (Civo Object Store and barman plugin).

- 2026-09-06 — user decision: replaced the Civo Object Store and barman-cloud
  design with shared logical dumps to S3. The Civo Object Store bills for a
  500 GB minimum, about 5.43 USD per month, while S3 bills for bytes stored,
  about 0.25 USD per month. Logical dumps also avoid a permanent AWS key,
  because this repository owns the job image and can use `credential_process`.

- 2026-09-11 — rescoped. This spec was previously the bucket, the image, the
  jobs, the teardown gate and the restore path in one. The jobs and the
  lifecycle wiring moved to CIVO-120, leaving this spec as the infrastructure
  and identity layer with its own independent proof. Three corrections were made
  against the code as it actually stands: Roles Anywhere consumers are hardcoded
  in the module rather than passed in; the daily CronJob was dropped in favour
  of a teardown-triggered backup; and "shared bucket" was replaced with one
  bucket per project, which is what CIVO-186 already assumed. The server image
  pin and the re-evaluation of CNPG's native object-store path were both added.
