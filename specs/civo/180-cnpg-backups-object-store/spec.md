---
id: "CIVO-180"
title: "Backup bucket, presigned-URL signing, and the server image pin"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One bucket module, one shell helper wrapping five lines of boto3, and one Helm value; no identity chain and no container image to publish"
effort_estimate: "Half a session (2-4 h) including one Civo bring-up for the smoke test"
estimate_confidence: "medium"
depends_on: ["CIVO-040", "CIVO-115"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-12"
completed: null
---

# CIVO-180 — Backup bucket, presigned-URL signing, and the server image pin

## 1. Outcome and rationale

A pod on Civo writes an object into this project's backup bucket and reads it
back, holding no AWS credential and no AWS identity of any kind. The URL it
uses is signed by the lifecycle script on the operator's machine, which already
holds AWS credentials, and is valid for one HTTP method on one key for a few
minutes.

This spec delivers the bucket, the signing helper, and the image pin that keeps
`pg_dump` in step with the server. It does not back up a database — CIVO-120
does that, and it can only do it once these exist. Splitting them means the one
thing that could fail in an unfamiliar way (a presigned PUT reaching S3 from
outside AWS, through Civo's egress) is proven on its own, before any data
depends on it.

## 2. Scope and non-goals

In scope:
- An S3 bucket per project in the AWS persistent stack, and its name in SSM.
- `scripts/lib/s3-presign.sh`: presign a PUT or a GET for one key, plus the
  preflight that fails early when the signing dependency is missing.
- Pinning the CNPG server image so the PostgreSQL major version cannot drift
  away from the client tools the backup Job runs.
- One smoke test on a live Civo cluster proving a pod can PUT and GET through
  presigned URLs, and proving the three ways those URLs are scoped.

Not in scope:
- Any CNPG backup or restore behaviour, any CronJob, any change to
  `argo-up`/`argo-down` (CIVO-120).
- Any Kubernetes-side AWS identity. This design deliberately creates none —
  see §4.
- Enabling anything on the AWS target (CIVO-185).
- Point-in-time recovery. Logical dumps restore to the moment of the dump.
- A daily schedule. Backups are taken at teardown; see CIVO-120 §4.

## 3. Current state / evidence

- There is exactly one bucket-creating module in the repository,
  `terraform/modules/terraform-state`, used by `terraform/live/state` and
  `terraform/live/account-state` for Terraform's own backend. No backup bucket
  exists in any stack, and `terraform/live/persistent/` holds only `acm`,
  `route53`, `secrets` and `vpc`.
- The Civo lifecycle scripts already call AWS from the operator's machine:
  `scripts/lib/provider.sh:136,160` runs `aws ssm put-parameter` and
  `aws ssm get-parameter` on the `PROVIDER=civo` path, and
  `scripts/argo-up.sh:66,100` batches `aws ssm get-parameters`. Whatever runs
  `make up` or `make down` on Civo therefore already holds AWS credentials.
- `aws s3 presign` generates **GET URLs only**. Confirmed against
  `aws-cli/2.31.27`: its synopsis accepts `--expires-in` and the global options
  and has no `--method`. A presigned PUT must come from
  `boto3.client('s3').generate_presigned_url('put_object', …)`.
- No script in this repository uses `python3` today; `jq` is the shared
  dependency (`scripts/{argo-up,argo-down,status,persistent-down,…}.sh`).
  `python3` with `boto3 1.42.32` is present on the current operator machine.
  The GitHub `ubuntu-latest` runner ships Python 3.12.3, pip 24.0 and AWS CLI
  2.x, but **does not list `boto3`** among its installed software.
- S3 rejects `Transfer-Encoding: chunked` on a plain PUT; it requires a
  `Content-Length`. A dump piped straight into `curl -T -` therefore cannot be
  uploaded — the dump must land in a file first.
- The CNPG operator is chart `0.29.0`, app version 1.30.0
  (`gitops/templates/platform/shared/postgres/application.yaml:13-14`). The
  `Cluster` CR sets no `imageName`, so the server runs whatever that operator
  defaults to — PostgreSQL 18.4 today, and something else after a chart bump.
- The CNPG PostgreSQL image installs `postgresql-${PG_MAJOR}` and puts
  `/usr/lib/postgresql/${PG_MAJOR}/bin` on `PATH`, so it carries `pg_dump`,
  `pg_restore` and `psql` matching the server exactly. It installs no HTTP
  client.
- `gitops/values.yaml:30` is the repository's one pinned-by-digest image
  (`public.ecr.aws/rolesanywhere/credential-helper@sha256:…`), used by the
  Roles Anywhere sidecar. That sidecar stays where it is — ESO, ExternalDNS and
  cert-manager still need it. Nothing in this spec adds a consumer to it.

## 4. Design and contracts

- **The cluster holds no AWS identity.** No Roles Anywhere consumer, no
  certificate, no Pod Identity association, no ServiceAccount annotation, no
  credential in any Secret, ConfigMap or image. `CLAUDE.md` requires that a
  Kubernetes workload reaching AWS uses Pod Identity or Roles Anywhere rather
  than a static key; this workload reaches AWS through a URL that was signed
  elsewhere and carries no bearer credential at all, which is a stronger
  position than either. Recorded as an explicit exemption in ADR 0031's
  amendment rather than left to inference.
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
  *mechanism* and object contract. CIVO-186 depends on there being two.
- **Unit.** `terraform/live/persistent/backups` is applied by
  `make persistent-up` on both providers — the Civo project runs the AWS
  persistent stack already, for SSM. Lifecycle class Persistent: the bucket
  outlives `make down` and is destroyed only by `persistent-down`.
- **Bucket name to the operator** at `/${project}/persistent/backups/bucket_name`,
  plain `String` (ADR 0023 — a bucket name is not a credential).
- **Object layout.** `postgres/${cluster}-${YYYYMMDDTHHMMSSZ}.dump`, one flat
  prefix. The timestamp is UTC and lexically sortable, which makes "newest key"
  and "newest backup" the same question.
- **Signing helper.** `scripts/lib/s3-presign.sh` exposes two functions,
  `s3_presign_put` and `s3_presign_get`, each taking a bucket, a key and a
  lifetime in seconds and printing one URL. Both are implemented by one
  `python3 -` heredoc calling `generate_presigned_url` with SigV4, so PUT and
  GET share a single code path and a single failure mode. The helper signs with
  whatever credentials the surrounding script already resolved — the operator's
  profile, or CI's OIDC session — and creates no IAM resource of its own. The
  region is passed explicitly: SigV4 presigning requires it, and a URL signed
  for the wrong region answers with a redirect rather than an error.
- **`signature_version="s3v4"` and a regional endpoint are both mandatory, and
  neither is the default.** Verified 2026-09-12: `generate_presigned_url` called
  with only `region_name` returned a **SigV2** URL — `AWSAccessKeyId`,
  `Signature`, `Expires` — against the global `s3.amazonaws.com` endpoint. AWS
  disabled SigV2 for buckets created after June 2020, so that URL fails against
  a new bucket with a signature error that names nothing useful. Pass
  `botocore.config.Config(signature_version="s3v4")` and confirm the generated
  URL carries `X-Amz-Algorithm=AWS4-HMAC-SHA256` and a regional host. Assert it
  in the offline signing test, where it costs nothing to catch.
- **No signed `Content-Type`.** The URL is signed for the method and the key
  only. The uploader must send no `Content-Type` header, or the signature will
  not match.
- **Preflight.** `s3_presign_require` checks `python3 -c 'import boto3'` and
  exits non-zero with an actionable message naming `pip install boto3`. CIVO-120
  calls it at the top of the teardown gate, before anything touches the cluster,
  so a machine that cannot sign fails before it has begun a destructive
  sequence rather than after the database is already gone.
- **Job images are upstream, pinned by digest.** The backup and restore Jobs
  CIVO-120 adds use the CNPG PostgreSQL image for `pg_dump`/`pg_restore`/`psql`
  and `quay.io/curl/curl` for the HTTP transfer, in two containers sharing an
  `emptyDir`. This repository builds and publishes no image. An earlier draft
  of this spec specified `images/pg-backup` and a GHCR workflow; that image
  existed solely to host `credential_process`, and presigned URLs remove its
  only reason to exist.
- **Server image pin, and why it is one value.** `postgres.imageName` in
  `gitops/values.yaml` is set explicitly and feeds **both**
  `Cluster.spec.imageName` and the PostgreSQL container of CIVO-120's Jobs. A
  `pg_dump` older than the server refuses to run, and a dump restored into an
  older server fails; with one value feeding both, that skew is not merely
  unlikely but unrepresentable. This is the one change here that alters the AWS
  golden render.
- **Not `quay.io` by accident.** `docker.io/curlimages/curl` is the better-known
  name, but anonymous Docker Hub pulls are rate-limited per source IP, and Civo
  nodes share egress addresses. Pin `quay.io/curl/curl` by digest. The value
  itself lands in CIVO-120 alongside the manifests that reference it; this spec
  fixes the choice so that decision is not re-litigated there.

## 5. Files/components affected

New: `terraform/modules/s3-backups/`, `terraform/live/persistent/backups/`,
`scripts/lib/s3-presign.sh`.

Modified: `gitops/values.yaml` (`postgres.imageName` only),
`gitops/templates/platform/shared/postgres/cluster.yaml` (`imageName`),
`tests/golden/gitops-aws/` (one key, deliberately). The curl image digest and
the `postgres.backup.*` block land in CIVO-120, with the manifests that use
them.

No Terraform IAM. No `gitops/templates/platform/civo/identity/` change. No
`.github/workflows/` change — CIVO-185 adds the CI dependency step, because
`lifecycle-test.yml` is the only workflow that runs a teardown today and it
runs the AWS one.

## 6. Implementation steps

1. Write the bucket module and unit. `PROVIDER=civo make persistent-up`.
   Confirm the bucket, its public-access block, its TLS-only policy, and the
   SSM parameter.
2. Write `scripts/lib/s3-presign.sh`. `shellcheck` it. Prove both functions
   against the real bucket from the operator's machine with `curl`, before any
   cluster is involved.
3. Pin `postgres.imageName` and regenerate the golden render with `MODE=update`
   — **its own commit**, so a one-key diff is reviewable alone.
4. `PROVIDER=civo make up`. Run the smoke test in §9.
5. Record the measured round-trip and the URL lifetime that worked, so CIVO-120
   can size its timeouts from a number rather than a guess.

## 7. Dependencies and blockers

CIVO-040 supplies the Civo cluster and kubeconfig the smoke test needs.
CIVO-115 supplies the `Cluster` manifest the image pin edits.

**The identity chain is no longer a dependency.** Earlier drafts of this spec
depended on CIVO-082, CIVO-085 and CIVO-100 because the Job was to authenticate
as a fourth Roles Anywhere consumer. It authenticates as nothing now, so those
edges are removed from the roadmap graph and the critical path.

## 8. Acceptance criteria

- `${project}-backups` exists for both projects, is not publicly readable, and
  rejects plaintext HTTP.
- From a pod on Civo carrying no AWS credential, no AWS config and no mounted
  certificate: a presigned PUT uploads a file, and a presigned GET returns it
  byte-identical.
- The URL is scoped in three independent ways, each stated as a test rather
  than an intention:
  - an expired URL returns `403`;
  - a GET-signed URL used with `PUT` returns `403`;
  - a URL signed for key A, used against key B, returns
    `SignatureDoesNotMatch`.
- `grep` over the diff finds no IAM role, policy, Roles Anywhere consumer,
  Pod Identity association, `Certificate`, or ServiceAccount annotation.
- No permanent AWS key exists in the repository, the cluster, SSM, or any image.
- `s3_presign_require` fails with a named, actionable message on a machine
  without `boto3`, and does so before any cluster call.
- The AWS golden diff is empty apart from the deliberate `imageName` commit,
  whose diff is exactly one key on one object.
- `PROVIDER=aws make -n up` output is unchanged.

## 9. Validation

Offline: `terraform fmt`/`validate`, `terragrunt validate`, `shellcheck`,
`make gitops-check`.

Signing test, no cluster: presign a PUT and a GET from the operator's machine
and round-trip a file with `curl`. This isolates the signing code from Civo's
egress — if step 2 passes and the pod fails, the fault is network, not
signature.

Smoke test, on a live Civo cluster: `kubectl run` a `quay.io/curl/curl` pod
with the two URLs in its arguments, upload, download, compare checksums, then
run the three negative cases.

Real cloud: one short Civo cluster session, well under 1 USD. The bucket itself
is about 0.25 USD per month at the expected volume. No Let's Encrypt production
order is spent — the existing certificate round-trips through SSM.

## 10. AWS regression protection

Nothing here is wired into any workload on either target. The bucket is new AWS
infrastructure with no consumer; the helper is a new shell file nothing sources
yet. The golden render must be empty for every commit in this spec except step
3's, whose diff is one key. `PROVIDER=aws make -n up` and `make -n down` output
must be unchanged, which they are by construction since no script is modified.

## 11. Rollout and rollback/recovery

Data risk: none. Nothing in this spec reads or writes a database. Rollback is
reverting the commits and destroying the bucket, which at this point holds only
the smoke test's object.

## 12. Risks and unresolved questions

- **`boto3` is a new operator dependency.** It is present on the current
  operator machine and absent from `ubuntu-latest`. The preflight makes the
  failure early and legible rather than mysterious; CIVO-185 adds the
  `pip install boto3` step to `lifecycle-test.yml`, and CIVO-140 owns it for a
  Civo CI path that does not exist yet. **Rejected alternative:** hand-rolling
  SigV4 query presigning in `bash` with `openssl`, which removes the dependency
  at the cost of about thirty-five lines of cryptographic shell that must also
  handle `X-Amz-Security-Token` for CI's session credentials. Revisit only if
  the dependency proves genuinely awkward in CI.
- **A presigned URL's lifetime is capped by the lifetime of the credential that
  signed it.** CI's OIDC session is roughly an hour; a URL with a longer
  `--expires-in` silently stops working when the session ends, not when the URL
  expires. CIVO-120 must size dump and restore timeouts inside that bound.
- **Whether the CNPG image already carries `curl` is unverified** — no Docker
  daemon was available to inspect it, and its Dockerfile installs no HTTP
  client explicitly. The design assumes it does not and uses two containers. If
  it turns out to carry one, each Job collapses to a single container; that is a
  simplification, not a correction.
- **The shared `emptyDir` crosses two UIDs.** The CNPG image runs as UID 26; the
  curl image does not. Default `0644` is enough for the reader in both
  directions, but CIVO-120 should set `fsGroup` explicitly rather than discover
  `Permission denied` on a live cluster.
- The URL appears in the Job's container arguments, so anyone who can
  `kubectl get pod -n cnpg-system -o yaml` can use it until it expires. That is
  a narrower grant than any standing credential the alternatives would have
  placed in the same namespace, and it is bounded in method, key and time.

## 13. Definition of done

- [ ] Bucket, SSM parameter, signing helper and image pin in place
- [ ] Signing proven without a cluster, then from a pod on Civo
- [ ] Three negative cases recorded
- [ ] Golden render empty except the deliberate `imageName` commit
- [ ] Index and roadmap updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT (Civo Object Store and barman plugin).

- 2026-09-06 — user decision: replaced the Civo Object Store and barman-cloud
  design with shared logical dumps to S3. The Civo Object Store bills for a
  500 GB minimum, about 5.43 USD per month, while S3 bills for bytes stored,
  about 0.25 USD per month. Logical dumps also avoided a permanent AWS key,
  because this repository would own the job image and could use
  `credential_process`. (That last clause was superseded on 2026-09-12; it is
  kept here because this entry records what was decided then.)

- 2026-09-11 — rescoped. This spec was previously the bucket, the image, the
  jobs, the teardown gate and the restore path in one. The jobs and the
  lifecycle wiring moved to CIVO-120. Three corrections were made against the
  code as it stands: Roles Anywhere consumers are hardcoded in the module rather
  than passed in; the daily CronJob was dropped in favour of a
  teardown-triggered backup; and "shared bucket" was replaced with one bucket
  per project.

- 2026-09-12 — **credential design replaced.** The operator reviewed the full
  option set for reaching S3 from Civo and chose presigned URLs minted by the
  lifecycle scripts over a fourth Roles Anywhere consumer. The scripts already
  hold AWS credentials on the Civo path (`provider.sh:136,160`), so the cluster
  needs no identity at all. Three consequences, each verified rather than
  assumed: `aws s3 presign` is GET-only on `aws-cli/2.31.27`, so PUT signing
  needs `boto3`, which `ubuntu-latest` does not ship; S3 rejects chunked PUT, so
  the dump must be a file before it is uploaded; and the repository-owned image
  loses its only justification, because ADR 0031 wanted it solely to host
  `credential_process`. The image, its GHCR workflow, the `pgbackup` Roles
  Anywhere consumer, its certificate and the AWS Pod Identity wrapper are all
  removed from this spec. Difficulty M to S; `depends_on` drops the entire
  identity chain.
