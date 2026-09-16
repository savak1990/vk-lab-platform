# CIVO-120: PostgreSQL persistence on Civo through the barman-cloud plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rows written before `PROVIDER=civo make down` are present after `make up`, restored by CloudNativePG from continuous physical backups in a per-project S3 bucket.

**Architecture:** The barman-cloud CNPG-I plugin injects a backup sidecar into the Postgres instance pod. That sidecar inherits the `postgres` container's volume mounts, so `Cluster.spec.projectedVolumeTemplate` delivers an IAM Roles Anywhere certificate and an AWS config file to it. botocore runs `aws_signing_helper credential-process` on demand, so no long-lived AWS credential exists anywhere.

**Tech Stack:** Terraform/Terragrunt, Helm and Argo CD, CloudNativePG 1.30 with `plugin-barman-cloud` v0.15.0, cert-manager, IAM Roles Anywhere, Bash lifecycle scripts, Go e2e tests.

**Spec:** `specs/civo/120-cnpg-on-civo-persistence/spec.md` and `specs/civo/180-cnpg-backups-object-store/spec.md` — **both still describe the superseded logical-dump design; task 14 rewrites them.** Until then the authority is this document.

**Supersedes:** `docs/adr/0031-logical-backups-to-s3.md`, whose blocking premise is false. Task 5 records that.

## Execution status

- **Tasks 1–3: merged** in PR #2 (`d4e116c`). The bucket module and unit, the `pgbackup` Roles Anywhere consumer, the sidecar image and its build workflow are all on `main`.
- **The image is built and anonymously pullable.** Pin this digest in task 6:
  `ghcr.io/savak1990/vk-lab-platform/cnpg-barman-sidecar@sha256:25332843178ff9560b176f7c6c22006c1b361cb249bae7f52728d733f7d98cda`
- **Checkpoint A step 5 turned out unnecessary** — a GHCR package pushed from a public repository inherits that visibility, so no manual step is needed. An anonymous manifest fetch returns HTTP 200.
- **Task 4 (spike): all four gates passed** on a live Civo cluster. Evidence in `specs/civo/120-cnpg-on-civo-persistence/spec.md` §14.
- **Tasks 6–9: merged** in PR #7 (`330fd65`). The plugin Application, the `ObjectStore`, the AWS config ConfigMap, the `ScheduledBackup`, the Cluster wiring, the values in all three places, `argo-up.sh` and the render check are on `main`. Verified live: 7 Applications `Synced/Healthy`, `ContinuousArchiving=True`, a `method: plugin` Backup `completed`, objects under the new generation prefix. The cluster's root Application was repointed at `main` after the merge.
- **Tasks 5, 10 and 12: this branch.** ADR 0032 plus the pointer notes; the constitution §4 relaxation and the architecture prose; `civo_backup()` rewritten as best-effort with a forced WAL switch; `CI_TEARDOWN_ALLOW_DATA_LOSS` removed from every live contract.
- **`CI_TEARDOWN_ALLOW_DATA_LOSS` deliberately survives in one place:** the body of CIVO-115, which is `DONE`. Deleting it there would falsify the record of what that spec delivered. A superseded blockquote at the top of §1 directs readers not to re-implement the gate.
- **Remaining:** tasks 11 (`persistent-down` empties the bucket), 13 (e2e), 14 (the multi-cycle proof) and 15 (spec bookkeeping).
- **Two checks the advisor added to task 14:** confirm `ContinuousArchiving` on a *fresh* bring-up, where the certificate may not exist when the Cluster first syncs (`optional: true` should let the pod start and self-heal, but that has never been watched); and confirm the base-backup count under one generation is bounded rather than monotonic, because no retention pruning cycle has ever run.

---


## Context

Civo's CSI driver (`csi.civo.com`) implements no snapshot and no clone capability, so the AWS recovery path (ADR 0013, CNPG `VolumeSnapshot`) has no Civo equivalent. ADR 0031 therefore chose logical `pg_dump` files in S3, on the stated premise that *"CNPG has no supported way to add a container of one's own to its managed instance pods"*.

**That premise is false.** The barman-cloud CNPG-I plugin injects exactly such a sidecar, and this repo can control its image. Two facts read from source make the whole design work:

- `plugin-barman-cloud` v0.15.0, `internal/cnpgi/operator/lifecycle.go`: `sidecar.VolumeMounts = ensureVolumeMount(sidecar.VolumeMounts, spec.Containers[i].VolumeMounts...)` — **the sidecar inherits every volume mount from the `postgres` container.**
- CloudNativePG `Cluster.spec.projectedVolumeTemplate` mounts arbitrary Secrets and ConfigMaps into instance pods at `/projected`.

So the Roles Anywhere certificate reaches the sidecar as a real mounted file, and a mounted file updates in place when cert-manager rotates it.

**Outcome:** rows written before `PROVIDER=civo make down` are present after `make up`, restored by CNPG from continuous physical backups in a per-project S3 bucket. Point-in-time recovery returns, which ADR 0031 had given up. The AWS target is untouched.

**Scope note:** this absorbs CIVO-180's mechanism work (bucket, IAM, image, plugin, ObjectStore) and CIVO-120's proof. Both specs are rewritten; 180 keeps the bucket, image and IAM, 120 keeps the Cluster wiring and the cycle proof.

---

## Design decisions

**D1 — Credentials: `credential_process`, no wrapper, no background process.**
The sidecar image is upstream plus one binary, entrypoint unchanged:

```dockerfile
FROM ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar@sha256:<v0.15.0 digest>
COPY --from=helper /aws_signing_helper /usr/local/bin/aws_signing_helper
# ENTRYPOINT ["/manager"], USER 26:26, PATH all inherited
```

The certificate and an AWS config file arrive through `projectedVolumeTemplate`; `AWS_CONFIG_FILE` points at the config. botocore runs `credential_process` on demand and caches the result.

This beats `serve` + a supervisor on four counts: the base is distroless with no shell, so a wrapper would need its own static binary; a crashlooping entrypoint would block the Postgres pod entirely, because the sidecar is a native sidecar (an initContainer with `restartPolicy: Always`); there is no listener, so no startup race against the first WAL archive; and the helper is spawned fresh each time, so it always reads the current certificate.

**D2 — `serverName` is generation-scoped.** With a constant `serverName`, cycle 2 archives WAL into the prefix it just recovered from and the timeline history collides. Each bring-up mints `lab-postgres-<UTC timestamp>` and recovers from the previous one. The current generation lives in SSM `/<project>/persistent-civo/postgres-backup/server_name` (plain `String`, ADR 0023), written by `argo-up` **after** the root Application reports healthy, so a failed bring-up does not burn the pointer.

**D3 — AWS environment goes on `Cluster.spec.env`, not `instanceSidecarConfiguration.env`.** The plugin merges the `postgres` container's env into the sidecar first and it wins; and `Cluster.spec.env` changes trigger an instance rollout, sidestepping upstream issues #824 and #918 where sidecar-config changes are not applied promptly.

**D4 — The teardown `Backup` is the real mechanism.** A daily `ScheduledBackup` on a cluster that may live less than a day can never fire, and plugin-side retention pruning only runs inside a live cluster. Keep the schedule with `immediate: true` for a base backup shortly after bootstrap, and make `argo-down` create and wait on a `Backup` CR.

**D5 — `CI_TEARDOWN_ALLOW_DATA_LOSS` is removed repo-wide.** Teardown never asks for confirmation. The pre-teardown backup is best-effort: it runs, warns loudly on failure, and continues. Continuous WAL archiving means the last archived segment is already durable before teardown starts, so a failed final `Backup` no longer means the only copy is about to be destroyed.

---

## Tasks

### 1. Backup bucket — Terraform

**Files:** create `terraform/modules/postgres-backups/{main.tf,variables.tf,outputs.tf,versions.tf}`, `terraform/live/persistent-civo/backups/terragrunt.hcl`.

Bucket `${project}-postgres-backups`. Copy the shape of `terraform/modules/terraform-state/main.tf`: SSE-S3 `AES256` with `bucket_key_enabled`, full public access block, a `DenyInsecureTransport` bucket policy, `force_destroy = false`. Versioning off. One lifecycle rule as a **backstop only** — expire the backup prefix after 30 days and abort incomplete multipart uploads after 7 — set well above the `retentionPolicy` window, because an aggressive rule deletes WAL segments a surviving base backup still needs. Publish SSM `/${project}/persistent-civo/backups/bucket_name` as `String`.

It goes in `persistent-civo`, not `persistent`: the latter applies on **both** providers and would create an AWS bucket. `root.hcl` derives `Lifecycle = persistent` from the directory name automatically.

**Verify:** `terraform fmt -check`, `terragrunt validate`, then `PROVIDER=civo make persistent-up` and confirm the bucket policy, the lifecycle rule and the four required tags.

### 2. `pgbackup` Roles Anywhere consumer — Terraform

**Files:** `terraform/modules/rolesanywhere/main.tf`.

Add `pgbackup` to the hardcoded `local.consumers` map. That alone creates role `${project}-ra-pgbackup`, adds it to the shared profile, writes SSM `/${project}/bootstrap/rolesanywhere/role_arn/pgbackup`, and builds a trust policy conditioned on common name `${project}-civo-pgbackup`.

Policy — on the bucket ARN: `s3:ListBucket`, `s3:ListBucketMultipartUploads`, `s3:GetBucketLocation`. On `${bucket}/*`: `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`. `DeleteObject` is what makes `retentionPolicy` pruning work; the multipart actions are what makes a large base backup work.

Build the ARN as the literal string `arn:aws:s3:::${var.project}-postgres-backups`. Do **not** add a data source or a dependency — `bootstrap` applies before `persistent-civo`.

Leave `session_duration` at 3600. It already clears botocore's 15-minute refresh threshold four times over, and the profile is shared with eso, external-dns and cert-manager.

**Verify:** `PROVIDER=civo make bootstrap-up`, then `aws iam get-role-policy --role-name vk-civo-lab-ra-pgbackup --policy-name consumer`.

### 3. Sidecar image and build workflow

**Files:** create `images/cnpg-barman-sidecar/Dockerfile`, `.github/workflows/sidecar-image.yml`. No `make` target — the repo has no build or lint targets today, and local iteration is a plain `docker build`.

Base pinned by digest. A builder stage downloads `aws_signing_helper` for `X86_64/Linux` (Civo's `g4s.kube.medium` is x86_64) and verifies it with `sha256sum -c` against the checksum from the release page. Keep `USER 26:26` and the inherited `ENTRYPOINT`.

**Registry: GHCR, as a public package.** ECR private would need the cluster to authenticate on every pull, and an ECR token lasts 12 hours — that means a permanent credential in an `imagePullSecret`, which is what this design exists to avoid. ECR Public would work, but costs an ADR 0024 exception for a `us-east-1` provider alias, a new `aws_ecrpublic_repository` in the bootstrap layer, and `ecr-public` push permissions on the CI role. GHCR needs none of that: the repo is already public, and the push authenticates with the built-in `GITHUB_TOKEN`.

**Build shape: a separate ~25-line workflow**, triggered on `paths: images/**` plus `workflow_dispatch`, with `permissions: {contents: read, packages: write}`. It pushes to GHCR and prints the `...@sha256:...` reference for pinning.

It stays out of `lifecycle-test.yml` and `lab.yml` for two reasons. Those workflows run with `id-token: write` and hold AWS credentials; adding `packages: write` there would permanently widen the most privileged tokens in the repo to save one small file. And the image is a **pinned dependency, not a per-run artifact** — building it inside the lifecycle test would either override the committed digest, so the cluster runs something `main` does not declare, or build and discard the result. It changes only when the plugin version moves.

**The GHCR package must be made public** — there is no `imagePullSecret` anywhere in this repo, so a private package means `ImagePullBackOff` and the Postgres pod never starts. One manual step; record it in the spec.

**Verify:** workflow green; pull the digest from a scratch pod on the Civo cluster before the spike.

### Checkpoint A — merge tasks 1–3 to `main` and build the image

Tasks 1–3 land together before the spike starts, because the spike must exercise the real bucket, the real IAM role and the real image rather than hand-made stand-ins.

1. Branch off `main` (the working tree is currently on `main`, and this repo branches before committing). One branch carries tasks 1, 2 and 3.
2. Open a PR. Confirm the fast-validation workflows pass: `validate-terraform`, `validate-gitops`, `validate-yaml`, `validate-actions`, `validate-secrets`. No GitOps object changed yet, so `make gitops-check` must still show an empty diff on all three goldens.
3. Merge to `main`. The push touches `images/**`, so `sidecar-image.yml` fires on its own.
4. Watch the run. Copy the `...@sha256:...` reference from the job summary.
5. **Make the GHCR package public.** It is private on first push, and there is no `imagePullSecret` anywhere in this repo. Skipping this means `ImagePullBackOff` and the Postgres pod never starts.
6. Prove the image is pullable from the cluster, not just from a workstation:
   ```bash
   kubectl run pull-probe --image=<digest> --restart=Never \
     --command -- /manager --help
   kubectl get pod pull-probe -o jsonpath='{.status.phase}'
   kubectl delete pod pull-probe
   ```
7. Apply the Terraform: `PROVIDER=civo make bootstrap-up`, then `PROVIDER=civo make persistent-up`. Confirm the bucket, the `pgbackup` role policy and both SSM parameters.

Hold the digest for the spike. It is committed into `gitops/values.yaml` in task 6, not here.

**Do not start task 4 until the pull probe reaches `Succeeded`.**

### 4. Spike — decision gate, on a real Civo cluster

**Files:** none committed except evidence appended to `specs/civo/120-cnpg-on-civo-persistence/spec.md` §14.

Tasks 1–3 must land first, so the spike exercises the production identity path. Install the plugin by hand, hand-write a `Certificate` in `cnpg-system` with common name `<project>-civo-pgbackup` and secret `pgbackup-ra-cert` — but with **`duration: 1h, renewBefore: 55m`** for the spike, not 24h. Then patch the `Cluster` with `projectedVolumeTemplate`, `spec.env` and `spec.plugins`.

Four gates, all must pass:

- **(a) The mount reaches the sidecar.** `kubectl get pod lab-postgres-1 -o jsonpath='{.spec.initContainers[?(@.name=="plugin-barman-cloud")].volumeMounts}'` must contain `/projected`. The image is distroless with no shell, so there is no `kubectl exec` path — confirm functionally through (b), or with `kubectl debug --target`.
- **(b) S3 works.** Create a `Backup` CR, then confirm `ContinuousArchiving=True` on the Cluster and that `aws s3 ls s3://<bucket>/lab-postgres-<gen>/` shows `base/` and `wals/`.
- **(c) Rotation survives.** After the 1-hour certificate rotates, keep forcing `select pg_switch_wal()` and keep asserting archive success **past the `notAfter` of the certificate that was on disk at pod start**. Elapsed wall-clock is not the test; that timestamp is.
- **(d) RBAC.** Upstream issue #892 says IAM-backed ObjectStores emit a wildcard `secrets get/list/watch` Role. This repo has no restrictive operator RBAC, so it should pass — confirm it here rather than discovering it in task 6.

Also record barman's RSS during a base backup (`kubectl top pod --containers`). There is ~2308 MiB allocatable per node and ~6.76 GiB total; those numbers size `instanceSidecarConfiguration.resources` in task 6.

**Fallbacks, named now:**

| Gate fails | Fallback |
|---|---|
| (a) mount not inherited | Abandon this design. Fall back to a refresher CronJob writing STS values into a Secret referenced by `s3Credentials` — no permanent key, but a short-lived one in etcd. |
| (b) `credential_process` not reached | Check the botocore chain order: any `AWS_ACCESS_KEY_ID` in the environment wins over the profile. Then try `serve` on `127.0.0.1:9911` with `AWS_EC2_METADATA_SERVICE_ENDPOINT`, which needs a static-binary entrypoint. |
| (c) helper caches the certificate | Should not happen with `credential_process`, which spawns fresh. If it does, give the `pgbackup` Certificate a long duration and document the deviation. |

**Do not start task 6 until all four pass.**

### 5. ADR and constitution

**Files:** create `docs/adr/0032-barman-cloud-plugin-backups-on-civo.md`; pointer note on `docs/adr/0031-logical-backups-to-s3.md` and `docs/adr/0013-postgres-volumesnapshot-recovery.md`; amend `specs/000-constitution/spec.md` §4 and `docs/architecture.md` (~line 550).

The ADR records: 0031's premise is false, citing `ensureVolumeMount`; PITR returns on Civo; retention is a recovery window, not a count, because `retentionPolicy` matches `^[1-9][0-9]*[dwm]$` and a daily schedule with `2d` keeps roughly 2–3 base backups; the §4 relaxation from D5, with its rationale; and the two pieces of new owned surface — the first image this repo builds and the first S3 lifecycle rule.

Constitution §13 requires more than an ADR: the §4 text itself and the architecture prose must both be amended. Grep for stale "logical dump" claims in `docs/architecture.md`, `specs/civo/architecture.md`, `specs/civo/decisions.md` and `docs/civo-high-level-design.md`.

### 6. GitOps — plugin, ObjectStore, Cluster wiring

**Files:** create `gitops/templates/platform/civo/postgres/{barman-plugin-application,objectstore,aws-config,scheduled-backup}.yaml`; modify `gitops/templates/platform/shared/postgres/cluster.yaml`, `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`.

Everything new is gated `{{- if eq .Values.target "civo" }}`.

- **Plugin Application**, wave 1 — after cert-manager's Application at wave 0, which the plugin needs for its own serving certificate, and before the Cluster at wave 3. Destination namespace `cnpg-system`; the plugin **must** live in the operator's namespace. Pin the sidecar image by setting the `SIDECAR_IMAGE` environment variable on the plugin Deployment through the Application's Helm values — the chart's `sidecarImage.registry/repository/tag` composes `registry/repository:tag` and probably cannot express a digest. Confirm that before writing it. Also confirm this Argo CD accepts a bare `oci://` `repoURL`; the existing `cnpg-operator` Application uses an HTTP repo.
- **ConfigMap `pgbackup-aws-config`**, wave 1, holding the profile:
  ```ini
  [default]
  credential_process = /usr/local/bin/aws_signing_helper credential-process --certificate /projected/ra/tls.crt --private-key /projected/ra/tls.key --trust-anchor-arn <...> --profile-arn <...> --role-arn <...> --region eu-west-1
  ```
- **ObjectStore `lab-postgres-backups`**, wave 2, `SkipDryRunOnMissingResource=true` because its CRD arrives with the wave-1 Application. `destinationPath: s3://<bucket>/`, **`s3Credentials.inheritFromIAMRole: true`** — mandatory, because any other setting makes `barman-cloud/pkg/credentials/env.go` append `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, which win through Go's `os/exec` last-wins rule; and omitting credentials entirely is rejected with `no credentials defined`. `wal.compression: gzip`, `data.compression: gzip`, `retentionPolicy: "2d"`, plus `instanceSidecarConfiguration.resources` from the spike.
- **Cluster** gains three Civo-only blocks:
  - `projectedVolumeTemplate.sources` — the Secret with `items` mapping `tls.crt` and `tls.key` to `ra/tls.crt` and `ra/tls.key`, and the ConfigMap mapping `config` to `aws/config`. **`optional: true` on the Secret source is load-bearing**: a missing Secret must not wedge pod creation.
  - `spec.env` — `AWS_CONFIG_FILE=/projected/aws/config`, and **both** `AWS_REGION` and `AWS_DEFAULT_REGION`, because `inheritFromIAMRole` returns before barman sets either.
  - `spec.plugins` — `barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`, `barmanObjectName: lab-postgres-backups`, `serverName` from values.
  - `bootstrap` gains a third branch: when the target is civo and `postgres.backup.recoverServerName` is non-empty, `bootstrap.recovery` with `source: lab-postgres-previous`, plus an `externalClusters` entry pointing the plugin at that `serverName`. **No `initdb` fallback on that branch** — a loud failure beats silently wiping a recoverable database, the same philosophy as the AWS branch.
- **`civoIdentity.consumers`** gains `{name: pgbackup, namespace: cnpg-system}`, which produces `pgbackup-ra-cert` at wave 1 with the matching common name.
- **Values** need the usual three edits for each new key: `postgres.backup.{bucket,sidecarImage,serverName,recoverServerName}`.

### 7. ScheduledBackup

**Files:** `gitops/templates/platform/civo/postgres/scheduled-backup.yaml`.

Wave 4, which is free — the current maximum is 3. `schedule: "0 0 3 * * *"` (CNPG uses a six-field, seconds-first spec), `immediate: true`, `backupOwnerReference: self`, `method: plugin`, `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`. `immediate: true` is what makes this useful at all on a cluster that may live less than a day.

### 8. Render check

**Files:** `scripts/gitops-render-check.sh`.

Civo and local render in a loop at lines 121–125; the new objects need `--set postgres.backup.enabled` style flags applied to `civo` only inside that loop. Add to `REQUIRED_OBJECTS_CIVO`: the plugin Application, `ObjectStore__cnpg-system__lab-postgres-backups`, `ScheduledBackup__cnpg-system__lab-postgres`, `Certificate__cnpg-system__pgbackup`, `ConfigMap__cnpg-system__pgbackup-aws-config`. Add the plugin Application to `FORBIDDEN_APPLICATIONS_LOCAL`, and `ObjectStore`/`ScheduledBackup` to `FORBIDDEN_KINDS_LOCAL`.

### 9. `argo-up` — SSM batch split and generation pointer

**Files:** `scripts/argo-up.sh`.

`civo_resolve_inputs()` fetches exactly 10 names today and its own comment says 10 is the `aws ssm get-parameters` cap. It now needs 12. Refactor the fetch into a helper taking an array and appending into the same parallel arrays, call it twice, and leave the per-name `case` loop and the fail-hard "missing SSM parameter" path intact.

`server_name` is the one **optional** name — it does not exist on the first run — so fetch it separately with `get-parameter || true` rather than through the fail-hard loop.

`civo_install_root_application()` gains `--set` for the bucket, the sidecar image digest, the new `serverName` and `recoverServerName`. After the root Application reports healthy, write the new generation back to SSM with `--overwrite`.

### 10. `civo_backup` and `civo_recovery_handle`

**Files:** `scripts/lib/provider.sh`, `scripts/argo-down.sh`.

`civo_recovery_handle()` (currently a stub at lines 97–102) reads the SSM pointer and echoes it, or echoes nothing with an explanation on the first run. The call site at `argo-up.sh:331` keeps its shape.

`civo_backup()` (currently lines 104–120) is rewritten: no Cluster means return 0; otherwise force a final `pg_switch_wal()` and wait for `ContinuousArchiving`, which is what makes a row written seconds before `make down` survive; then create `Backup/lab-postgres-teardown-<epoch>` with `method: plugin` and wait. On failure or timeout, print a loud multi-line warning naming the last successfully archived WAL, and **return 0**. Mirror `aws_cnpg_backup_and_prune` at `argo-down.sh:80+` for the CR creation and wait loop.

Raise the timeout on the Civo path: `ARGO_DOWN_BACKUP_TIMEOUT` defaults to 120s, far too short for a base backup of a populated 20 GiB volume. Use 600s.

### 11. `persistent-down` empties the bucket

**Files:** `scripts/persistent-down.sh`.

Nothing empties any bucket today, and `force_destroy = false` means Terraform fails on a non-empty bucket. After the existing confirmation and before the `persistent-civo` destroy, `aws s3 rm s3://<bucket> --recursive`, tolerating a missing bucket. Add `persistent-civo/backups` to the hardcoded unit-prefix emptiness list at line ~143. Also delete the `server_name` SSM parameter here — a stale pointer with no bucket makes the next `make up` try to recover from nothing.

### 12. Remove `CI_TEARDOWN_ALLOW_DATA_LOSS`

**Files:** `scripts/lib/provider.sh` (done in task 10), `docs/architecture.md:550`, `specs/civo/{115,120,140,180}/spec.md`, `specs/hetzner/{016,115,120,140}/spec.md`.

The hetzner specs inherited the flag from civo and will re-introduce it if left. Leave `docs/superpowers/plans/*` alone — those are dated records. Replace each mention with the best-effort-backup contract rather than deleting the variable name and leaving a broken clause.

**Verify:** `grep -rn CI_TEARDOWN_ALLOW_DATA_LOSS . --exclude-dir=.git --exclude-dir=docs/superpowers` returns nothing.

### 13. e2e

**Files:** `tests/e2e/postgres_test.go`, possibly `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml`.

A Civo-gated test asserting `ContinuousArchiving=True` on the Cluster and at least one `Backup` in `completed`. The e2e identity is read-only, so reads only — the test never creates a Backup. Check whether the read-only ClusterRole covers `backups.postgresql.cnpg.io` and `objectstores.barmancloud.cnpg.io`; extending it **does** touch the AWS golden.

### 14. Spec bookkeeping

**Files:** `specs/civo/{120,180,185,186}/spec.md`, `specs/civo/{roadmap,decisions,README}.md`.

- **180** is written end-to-end for logical dumps — a `pg_dump` image, a daily CronJob, a restore Job, a Pod Identity role, a bucket under `persistent/`. Rewrite §§1, 2, 4, 5, 6 for the plugin design. It keeps the bucket, the image and the IAM.
- **120**: §4's "bootstrap is always `initdb`", the PostSync restore Job, and the teardown flag are all now wrong. §5's `persistent-civo-artifacts.sh` is unnecessary — nothing is a retained artifact but the S3 objects. §8's "persistent-down empties it only after a confirmation" conflicts with the flag removal; the existing `CONFIRM_DESTROY` on `persistent-down` already covers it.
- **185** expected an AWS Pod Identity role from 180 that no longer exists. It should be re-scoped to migrating AWS onto the plugin too, which now makes sense because PITR works — and on AWS that needs Pod Identity with `inheritFromIAMRole: true` and none of the signing-helper machinery. Flag as needing a redesign.
- **186** rests entirely on `pg_dump --no-owner --no-privileges` portability. Physical base backups plus WAL are not portable that way. Set `status: BLOCKED`, `blocked_by: ["CIVO-185"]`.

---

## Hazards

1. **The AWS golden diff cannot stay empty.** `tests/golden/gitops-aws/bootstrap` contains the rendered root Application, so every new `helm.parameters` entry changes it. Regenerate with `./scripts/gitops-render-check.sh update` and restate the acceptance criterion: *the `platform` and `platform-recovery` goldens are unchanged; the `bootstrap` golden gains only the new empty-valued parameters.* Review that diff line by line.
2. **`serverName` collision on cycle 2** is the single most likely failure in the final proof. D2 addresses it; without it, recovering from a recovered cluster corrupts the archive.
3. **Ordering: role before certificate.** Adding `pgbackup` to `civoIdentity.consumers` before the Terraform role exists produces a certificate whose common name no trust policy matches, and the helper then fails with an opaque error. Land task 2 and re-apply `bootstrap` first.
4. **GHCR visibility.** Private by default, no imagePullSecret in this repo. Make it public before the spike.
5. **Digest pinning through the chart.** `sidecarImage.*` composes `registry/repository:tag` and likely cannot express a digest. Verify against the chart template; the fallback is setting `SIDECAR_IMAGE` directly, which takes a full reference.
6. **The Cluster at wave 3 may start before the plugin Deployment is ready.** Argo's retry budget plus CNPG's reconciliation should cover it. Add a readiness hook only if a real bring-up wedges, and copy `webhook-ready-probe.yaml`'s pattern exactly: `hook: Sync`, `hook-delete-policy: BeforeHookCreation` and only that, with the ServiceAccount and RBAC at an explicitly earlier wave.
7. **Memory headroom.** ~2308 MiB allocatable per node. Postgres requests 256Mi, the sidecar adds more during a base backup, and the plugin Deployment lands somewhere too. Size from the spike, not from guesses.
8. **The "pointer exists but the bucket is empty" case must fail loudly.** No `initdb` fallback. Task 11's pointer deletion is what keeps the two states from disagreeing.

---

## Verification

**Offline, after every task that touches `gitops/`:** `make gitops-check`, and `terraform fmt -recursive -check` after Terraform changes. `bash -n` and `shellcheck` after script changes.

**End-to-end, the acceptance evidence, recorded verbatim in the spec:**

1. `PROVIDER=civo make up`. Confirm the `initdb` path, `serverName = lab-postgres-<gen1>`, the first ScheduledBackup completing, and the SSM pointer written.
2. Write rows, including **one final row immediately before teardown** — that is what proves the last WAL segment was archived, which a row written minutes earlier will not catch.
3. `PROVIDER=civo make down`. Confirm the teardown Backup completed and the final WAL is in S3.
4. `PROVIDER=civo make up`. Confirm recovery from `<gen1>`, that **all** rows including the final one are present, and that new archiving goes to a **different** prefix, `<gen2>`.
5. Repeat once. **Cycle 2 is the one that matters**: recovery from `<gen2>`, which was itself a recovered cluster. Check that `<gen2>/wals/` holds a `.history` file and that `<gen3>`'s archive is not polluted by `<gen2>`'s timeline.
6. Re-sync Argo without a teardown. Confirm nothing re-bootstraps and no data is touched.
7. One **AWS** `make down` / `make up` cycle, confirming the EBS VolumeSnapshot path still restores.
8. `grep -rniE 'AKIA[0-9A-Z]{16}'` finds nothing, and no SSM parameter holds an access key.

**Cost:** about 0.25 USD per month of S3 for a 20 GiB lab database's backups. Civo egress is free. Three validation cycles cost about 0.75 USD of Civo compute.
