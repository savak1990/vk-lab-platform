# CIVO-180 — CNPG barman-cloud backups to a per-project S3 bucket (Civo only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Civo CNPG cluster continuous physical backups to a per-project AWS S3 bucket through the CloudNativePG barman-cloud plugin, with no long-lived AWS key anywhere.

**Architecture:** The barman-cloud CNPG-I plugin injects a sidecar into the CNPG instance pod. That sidecar archives WAL and writes base backups to `s3://<project>-backups/`. The sidecar reads AWS credentials from a Kubernetes Secret through the `ObjectStore.spec.configuration.s3Credentials` secret references. A separate refresher `CronJob`, which owns its image and holds the `pgbackup` Roles Anywhere certificate, calls `aws_signing_helper credential-process` and writes the three temporary values into that Secret. The AWS target is untouched: every new object renders only when `.Values.target` is `civo`.

**Tech Stack:** Terraform/Terragrunt (AWS S3, IAM, IAM Roles Anywhere, SSM), Helm/Argo CD, CloudNativePG 1.26+ with `plugin-barman-cloud` v0.15.0, cert-manager, `aws_signing_helper` 1.8.5, Bash lifecycle scripts, Go e2e tests.

**Spec:** `specs/civo/180-cnpg-backups-object-store/spec.md` (this plan rewrites it — see Task 2)

---

## Global Constraints

- Provider scope: **Civo only**. The AWS target keeps ADR 0013's EBS `VolumeSnapshot` path. `make gitops-check` must report an **empty** golden diff for `tests/golden/gitops-aws/`.
- Region is the literal `eu-west-1`, declared once per layer, never from an env var (ADR 0024).
- Never write a real root domain into code, values or docs. Use `<root-domain>` / `lab.<root-domain>`.
- No plaintext secret in Git. No permanent AWS access key anywhere — in the repo, the cluster, or SSM (constitution §5, ADR 0029).
- Every Terraform-managed AWS resource carries `Project`, `Scope=platform`, `Lifecycle=persistent`, `ManagedBy=terraform` through the provider-level `default_tags` in `terraform/live/root.hcl:65-82`. Do not re-tag per resource.
- Terraform owns AWS resources. Argo CD owns Kubernetes resources. Never both.
- Bucket name: `${project}-backups`. On Civo `PROJECT_NAME=vk-civo-lab`, so `vk-civo-lab-backups`. One bucket per project, no cross-project grant (spec 186 §86).
- Retention is **barman's**, never an S3 lifecycle rule. An S3 rule would truncate the WAL chain and desynchronize barman's own metadata.
- `retentionPolicy` accepts `^[1-9][0-9]*[dwm]$` only — a recovery window. "Exactly 2 backups" is not expressible. A daily `ScheduledBackup` with `retentionPolicy: 2d` keeps about 2 to 3 base backups. Record this as an approximation, never as "2 backups".
- `CI_TEARDOWN_ALLOW_DATA_LOSS` is removed from the whole repository. Teardown never blocks on a backup result and never asks for a confirmation. A failed pre-teardown backup prints a loud warning and the teardown continues.
- Comments in code: only where the code is genuinely hard, at most 3 lines, never a reference to a spec, ADR or ticket number.
- Commit after every task. Run `make gitops-check` before every commit that touches `gitops/`.

---

## File Structure

**Terraform**
- Create `terraform/modules/s3-backups/{main.tf,variables.tf,outputs.tf,versions.tf}` — the backup bucket, its public-access block, its TLS-only policy, and the SSM parameter holding its name.
- Create `terraform/live/persistent-civo/backups/terragrunt.hcl` — the Civo-project instance of that module. Chosen over `terraform/live/persistent/backups/` because `persistent/` is applied on **both** providers by default, which would create an AWS bucket this task must not create.
- Modify `terraform/modules/rolesanywhere/{main.tf,variables.tf}` — add the `pgbackup` consumer and its S3 policy; raise the default session duration.

**Container image**
- Create `images/aws-session-credentials/{Dockerfile,refresh.sh}` — mints Roles Anywhere session credentials and writes them into a Kubernetes Secret.
- Create `.github/workflows/images.yml` — builds and pushes that image to GHCR, prints the digest.

**GitOps**
- Create `gitops/templates/platform/civo/postgres/backup-credentials.yaml` — ServiceAccount, Role, RoleBinding and the refresher `CronJob`.
- Create `gitops/templates/platform/civo/postgres/objectstore.yaml` — the barman `ObjectStore`.
- Create `gitops/templates/platform/civo/postgres/scheduledbackup.yaml` — the daily `ScheduledBackup`.
- Create `gitops/templates/platform/civo/postgres/plugin-application.yaml` — the Argo `Application` installing `plugin-barman-cloud`.
- Modify `gitops/templates/platform/shared/postgres/cluster.yaml` — add the Civo `plugins` block and the Civo recovery bootstrap.
- Modify `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml` — the new `postgres.backup.*` keys and the `pgbackup` role ARN.

**Scripts**
- Modify `scripts/argo-up.sh` — split the SSM batch (it is already at the 10-name cap) and pass the new values.
- Modify `scripts/lib/provider.sh` — replace the `civo_backup` refusal stub with a real fail-closed backup gate; make `civo_recovery_handle` report the object store.
- Modify `scripts/persistent-down.sh` — empty the backup bucket after confirmation and extend the emptiness check list.
- Modify `scripts/gitops-render-check.sh` — add the new Civo objects to `REQUIRED_OBJECTS_CIVO`.

**Docs and specs**
- Create `docs/adr/0032-cnpg-barman-plugin-physical-backups.md`.
- Modify `docs/adr/0031-logical-backups-to-s3.md` (pointer note only), `docs/adr/0013-postgres-volumesnapshot-recovery.md` (pointer note only).
- Rewrite `specs/civo/180-cnpg-backups-object-store/spec.md`; add notes to `specs/civo/{120,185,186}/spec.md` and `specs/civo/decisions.md`.

---

## Why this replaces the spec as written

Three facts, each verified against a primary source, break spec 180 §4 and ADR 0031:

1. **The barman-cloud plugin does inject a sidecar into the instance pod.** The plugin's own docs describe `instanceSidecarConfiguration` as "the configuration for the sidecar that runs in the instance pods". ADR 0031 and `specs/civo/decisions.md:34` both rest on "CNPG gives no way to add a sidecar to its instance pods", which is false. That was the only blocker against physical backups on Civo.
2. **Presigned S3 URLs cannot drive barman-cloud.** Barman-cloud uses boto3 and needs multi-object access — prefix listing, multipart upload, WAL read-back and retention deletes. A presigned URL grants one object, one method, one expiry. Barman 3.18's documented credential mechanisms are `--aws-profile`, environment variables and the default boto3 chain. There is no presigned mode.
3. **The sidecar cannot mount a certificate.** `instanceSidecarConfiguration` exposes `env`, `resources`, `additionalContainerArgs`, `logLevel` and `retentionPolicyIntervalSeconds` only. It has no `volumeMounts`, no `volumes` and no image override, so `credential_process` and a mounted Roles Anywhere certificate are both impossible inside that container.

`s3Credentials` accepts `accessKeyId`, `secretAccessKey` **and `sessionToken`** as secret references. That is the credential path this plan uses: temporary Roles Anywhere session credentials, refreshed into a Secret, never a permanent key.

`inheritFromIAMRole: true` is unusable here. It needs a credential source inside the instance pod, and only a plugin can add a container there.

---

### Task 1: Spike — prove the credential path before building anything

The whole design depends on one unverified behavior: what CloudNativePG does when a Secret referenced by `s3Credentials` changes. The sidecar receives those values as environment variables, and environment variables do not update in a running container. Answer this before writing production code.

**Files:**
- Create: `specs/civo/180-cnpg-backups-object-store/spike-notes.md`

**Interfaces:**
- Produces: a recorded decision — `REFRESH_MODE` is one of `rollout`, `long-session`, or `blocked` — consumed by Task 8's `CronJob` schedule and by Task 2's ADR text.

- [ ] **Step 1: Bring up a Civo cluster**

```bash
PROVIDER=civo make up
PROVIDER=civo kubectl get cluster lab-postgres -n cnpg-system
```

Expected: the `Cluster` reports `Cluster in healthy state`.

- [ ] **Step 2: Confirm the CloudNativePG version meets the plugin's floor**

```bash
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
```

Expected: a tag of `1.26.0` or newer. Chart `cloudnative-pg` `0.29.0` is pinned in `gitops/templates/platform/shared/postgres/application.yaml:15`. If the image is older than 1.26, record the chart version that ships 1.26+ in the spike notes; Task 9 must bump `targetRevision`.

- [ ] **Step 3: Install the plugin by hand**

```bash
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.0/manifest.yaml
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud --timeout=180s
```

Expected: `deployment "plugin-barman-cloud" successfully rolled out`. The plugin must live in the operator's namespace, `cnpg-system`.

- [ ] **Step 4: Create a throwaway credential Secret and an ObjectStore**

Use a temporary IAM user's keys for the spike only, in a scratch bucket. Delete both at the end of this task.

```bash
kubectl -n cnpg-system create secret generic spike-s3 \
  --from-literal=ACCESS_KEY_ID=... \
  --from-literal=SECRET_ACCESS_KEY=... \
  --from-literal=SESSION_TOKEN=...

cat <<'EOF' | kubectl apply -f -
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: spike-store
  namespace: cnpg-system
spec:
  retentionPolicy: 2d
  configuration:
    destinationPath: s3://SCRATCH-BUCKET/
    s3Credentials:
      accessKeyId:
        name: spike-s3
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: spike-s3
        key: SECRET_ACCESS_KEY
      sessionToken:
        name: spike-s3
        key: SESSION_TOKEN
    wal:
      compression: gzip
EOF
```

- [ ] **Step 5: Attach the plugin to the Cluster and record the pod generation**

```bash
kubectl -n cnpg-system patch cluster lab-postgres --type merge -p '{"spec":{"plugins":[{"name":"barman-cloud.cloudnative-pg.io","isWALArchiver":true,"parameters":{"barmanObjectName":"spike-store"}}]}}'
kubectl -n cnpg-system get pods -l cnpg.io/cluster=lab-postgres -o name
kubectl -n cnpg-system get pod lab-postgres-1 -o jsonpath='{.spec.containers[*].name}'
```

Expected: a second container name appears next to `postgres`.

- [ ] **Step 6: Answer the question — change the Secret and watch the pod**

```bash
kubectl -n cnpg-system get pod lab-postgres-1 -o jsonpath='{.metadata.uid}{"\n"}'
kubectl -n cnpg-system patch secret spike-s3 --type merge \
  -p "{\"stringData\":{\"SESSION_TOKEN\":\"changed-$(date +%s)\"}}"
sleep 120
kubectl -n cnpg-system get pod lab-postgres-1 -o jsonpath='{.metadata.uid}{"\n"}'
kubectl -n cnpg-system get events --sort-by=.lastTimestamp | tail -30
```

Read the result:
- **The pod UID changed** → CloudNativePG rolls the instance on a credential change. `REFRESH_MODE=rollout`. A single-instance lab cluster then takes a short restart on every refresh. Keep refreshes rare: raise the Roles Anywhere profile duration to 43200 s (12 h) in Task 4 and refresh every 8 h in Task 8.
- **The pod UID is unchanged and the sidecar still holds the old value** → the sidecar would keep expired credentials. `REFRESH_MODE=long-session`. Task 8 must then delete the instance pod itself after writing the Secret, and Task 8's RBAC needs `pods: delete` in `cnpg-system`.
- **Neither works** (for example the operator rejects the change, or WAL archiving fails after the change) → `REFRESH_MODE=blocked`. Stop. Report to the user before continuing; the fallback is an HTTPS credential-vending Service reached through `AWS_CONTAINER_CREDENTIALS_FULL_URI`, which is a much larger build.

- [ ] **Step 7: Verify a base backup actually lands**

```bash
kubectl -n cnpg-system create -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  generateName: spike-backup-
  namespace: cnpg-system
spec:
  cluster:
    name: lab-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl -n cnpg-system get backup -w
aws s3 ls s3://SCRATCH-BUCKET/ --recursive | head
```

Expected: the `Backup` reaches `phase: completed`, and objects appear under `lab-postgres/base/` and `lab-postgres/wals/`. If `method: plugin` is rejected, record the accepted spelling from `kubectl explain backup.spec` in the spike notes — Task 10 and Task 11 both depend on it.

- [ ] **Step 8: Record the findings and clean up**

Write `specs/civo/180-cnpg-backups-object-store/spike-notes.md` containing: the CloudNativePG version, the chosen `REFRESH_MODE` with the pod-UID evidence, the exact accepted `Backup` and `ScheduledBackup` spellings, the sidecar container name, and the S3 key layout observed.

```bash
kubectl -n cnpg-system delete objectstore spike-store secret spike-s3
kubectl -n cnpg-system patch cluster lab-postgres --type json -p '[{"op":"remove","path":"/spec/plugins"}]'
aws s3 rm s3://SCRATCH-BUCKET/ --recursive
```

Delete the temporary IAM user's access key in the AWS console.

- [ ] **Step 9: Commit**

```bash
git add specs/civo/180-cnpg-backups-object-store/spike-notes.md
git commit -m "spec(civo-180): record barman plugin credential-refresh spike findings"
```

---

### Task 2: Record the decision — ADR 0032 and the spec rewrite

**Files:**
- Create: `docs/adr/0032-cnpg-barman-plugin-physical-backups.md`
- Modify: `docs/adr/0031-logical-backups-to-s3.md` (add a Status pointer, do not rewrite the body)
- Modify: `docs/adr/0013-postgres-volumesnapshot-recovery.md` (add a pointer note)
- Modify: `specs/civo/180-cnpg-backups-object-store/spec.md` (rewrite §§1-14)
- Modify: `specs/civo/120-cnpg-on-civo-persistence/spec.md`, `specs/civo/185-aws-logical-backup-migration/spec.md`, `specs/civo/186-cross-provider-backup-promotion/spec.md`, `specs/civo/decisions.md`

**Interfaces:**
- Produces: the contract every later task implements — bucket name `${project}-backups`, consumer name `pgbackup`, Secret name `pgbackup-s3-credentials`, `ObjectStore` name `lab-postgres-backups`, values prefix `postgres.backup.*`.

- [ ] **Step 1: Write ADR 0032**

Follow the shape of `docs/adr/0031-logical-backups-to-s3.md`. Required content:

- **Status:** Accepted. Supersedes ADR 0031.
- **Context:** ADR 0031 rejected the barman route on the premise that CloudNativePG offers no way to add a container to its instance pods. The barman-cloud CNPG-I plugin does exactly that: its `ObjectStore` CRD carries an `instanceSidecarConfiguration` field described as "the configuration for the sidecar that runs in the instance pods". The premise is false, so the decision built on it must be reopened.
- **Decision:** Civo uses the barman-cloud plugin for continuous physical backups to a per-project S3 bucket. Credentials reach the sidecar as temporary Roles Anywhere session values in a Secret, written by a refresher `CronJob` that owns its own image. No permanent AWS key exists.
- **Consequences — state each explicitly:**
  - Point-in-time recovery returns. ADR 0031 surrendered it; this design restores it, because WAL is archived continuously.
  - The Civo Object Store rejection stands unchanged. The target is still AWS S3, at about 0.25 USD per month, against the Civo Object Store's 500 GB minimum at about 5.43 USD per month.
  - Retention is a recovery window, not a backup count. The plugin's `retentionPolicy` matches `^[1-9][0-9]*[dwm]$`. A daily schedule with `2d` keeps about 2 to 3 base backups.
  - Recovery is a new `Cluster` with `bootstrap.recovery`, not an in-place restore Job. ADR 0031's restore-Job design is withdrawn.
  - Logical dumps are not produced any more, so a dump is no longer portable between providers. CIVO-186 is blocked until a separate mechanism is chosen.
  - ADR 0013's failure philosophy carries forward: if a backup exists and recovery fails, the cluster stays down. There is no silent fallback to `initdb`.
  - AWS is unchanged. ADR 0013 remains the active AWS path.

- [ ] **Step 2: Add the pointer note to ADR 0031**

Under its `## Status` heading, replace `Accepted` with:

```markdown
Superseded by ADR 0032.

The load-bearing fact in this ADR's Context — that CloudNativePG offers no
supported way to add a container to its instance pods — is false. The
barman-cloud CNPG-I plugin injects exactly such a sidecar. The body below is
kept unrewritten, following the convention this ADR itself used for ADR 0013.
```

- [ ] **Step 3: Add the pointer note to ADR 0013**

Append one short paragraph under its Status: Civo's backup mechanism is ADR 0032, not this one; this ADR still governs the AWS target.

- [ ] **Step 4: Rewrite spec 180**

Keep the front-matter `id`, `title`, `milestone` and `priority`. Change:
- `title`: `"CNPG physical backups to a per-project S3 bucket on Civo"`
- `difficulty`: `"L"`, `effort_estimate`: `"Two to three sessions (10-14 h)"`
- `updated`: `"2026-09-15"`
- `depends_on`: keep `["CIVO-082", "CIVO-085", "CIVO-100"]`

Rewrite §2 Scope: in scope — the bucket, the `pgbackup` Roles Anywhere consumer, the refresher image and `CronJob`, the plugin `Application`, the `ObjectStore`, the `ScheduledBackup`, the Civo recovery bootstrap, the teardown gate, the `persistent-down` bucket emptying. Not in scope — the AWS target in any form, the CIVO-120 two-cycle proof, cross-provider promotion.

Rewrite §4 Design with the contract listed under **Interfaces** above, plus the three verified facts from "Why this replaces the spec as written".

Rewrite §12 Risks: the credential-refresh behavior and its `REFRESH_MODE` from Task 1; the retention approximation; the need for the sidecar's Postgres major version to match the server's, which the plugin handles because the sidecar ships with the operator release.

Fix the two stale line references the exploration found: §3 cites `scripts/argo-down.sh:54-113` and `scripts/argo-up.sh:167-197`. The real spans are `scripts/argo-down.sh:86-147` (invoked at 149-151) and `scripts/argo-up.sh:289-328` (dispatched at 330-334).

- [ ] **Step 5: Add the downstream notes**

In `specs/civo/120-cnpg-on-civo-persistence/spec.md` §14, append:

```markdown
- 2026-09-15 — CIVO-180 moved from logical dumps to CNPG barman-cloud physical
  backups (ADR 0032). Two contracts in this spec invert: §55's "bootstrap is
  always initdb, no recovery bootstrap" becomes a `bootstrap.recovery` from the
  object store, and §57's PostSync restore Job no longer exists. The teardown
  gate in §56 no longer blocks: it creates a CNPG `Backup` object, waits, warns
  on failure and lets the teardown proceed. `CI_TEARDOWN_ALLOW_DATA_LOSS` is
  removed from the repository — see CIVO-180 Task 11.
```

In `specs/civo/185-aws-logical-backup-migration/spec.md` §14, append: CIVO-180 no longer creates the AWS Pod Identity role that §59 expected, because the user scoped 180 to Civo only. 185 must create it. 185's own mechanism choice reopens — it can adopt the barman plugin instead of logical dumps.

In `specs/civo/186-cross-provider-backup-promotion/spec.md`, change `status` to `"BLOCKED"` and append to §14: this spec rests entirely on `pg_dump --no-owner --no-privileges` portability. Physical backups are not portable that way. Reopen only with a chosen mechanism.

In `specs/civo/decisions.md`, add an ADR 0032 row and mark the 2026-09-06 decision `(d) logical dumps` as superseded, naming the false premise.

- [ ] **Step 6: Verify the docs build and commit**

```bash
make yaml-lint 2>/dev/null || true
git add docs/adr specs/civo
git commit -m "docs(adr-0032): supersede ADR 0031 with CNPG barman plugin physical backups"
```

---

### Task 3: The backup bucket

**Files:**
- Create: `terraform/modules/s3-backups/{versions.tf,variables.tf,main.tf,outputs.tf}`
- Create: `terraform/live/persistent-civo/backups/terragrunt.hcl`
- Modify: `scripts/persistent-down.sh:143`

**Interfaces:**
- Produces: bucket `${project}-backups`; SSM parameter `/${project}/persistent-civo/backups/bucket_name` (type `String`); module outputs `bucket_name`, `bucket_arn`.

- [ ] **Step 1: Write the module's version pins**

Copy the exact pins from `terraform/modules/rolesanywhere/versions.tf` so every module in the repo agrees.

`terraform/modules/s3-backups/versions.tf`:

```hcl
terraform {
  required_version = "1.15.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.60.0"
    }
  }
}
```

- [ ] **Step 2: Write the variables**

`terraform/modules/s3-backups/variables.tf`:

```hcl
variable "project" {
  description = "Project name; prefixes the bucket and the SSM parameter path."
  type        = string
}

variable "force_destroy" {
  description = "Terraform never empties this bucket. persistent-down empties it after an explicit confirmation, matching the terraform-state module's convention."
  type        = bool
  default     = false
}
```

- [ ] **Step 3: Write the bucket**

`terraform/modules/s3-backups/main.tf`. No lifecycle rule: barman owns retention, and an S3 expiry would cut the WAL chain out from under it.

```hcl
resource "aws_s3_bucket" "this" {
  bucket        = "${var.project}-backups"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "deny_insecure_transport" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.deny_insecure_transport.json
}

resource "aws_ssm_parameter" "bucket_name" {
  name        = "/${var.project}/persistent-civo/backups/bucket_name"
  type        = "String"
  value       = aws_s3_bucket.this.id
  description = "This project's PostgreSQL backup bucket."
}
```

- [ ] **Step 4: Write the outputs**

`terraform/modules/s3-backups/outputs.tf`:

```hcl
output "bucket_name" {
  description = "The backup bucket's name."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "The backup bucket's ARN."
  value       = aws_s3_bucket.this.arn
}
```

- [ ] **Step 5: Write the terragrunt unit**

`terraform/live/persistent-civo/backups/terragrunt.hcl`. `persistent-civo` is applied on the Civo project only, which is what keeps this away from the AWS target.

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/s3-backups"
}

inputs = {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}
```

- [ ] **Step 6: Validate**

```bash
terraform fmt -recursive -check terraform/modules/s3-backups
cd terraform/live/persistent-civo/backups && terragrunt validate
```

Expected: both succeed. `terraform fmt -check` prints nothing.

- [ ] **Step 7: Extend the persistent-down emptiness check**

`scripts/persistent-down.sh:143` hardcodes the unit list. Add the new unit:

```bash
for unit_prefix in persistent/vpc persistent/secrets persistent-civo/network persistent-civo/reserved-ip persistent-civo/backups
```

- [ ] **Step 8: Empty the bucket before the destroy**

In `scripts/persistent-down.sh`, immediately before the `persistent-civo` destroy, add a guarded emptying step. It must run only after the script's existing confirmation prompt has passed.

```bash
empty_backup_bucket() {
  local bucket="${PROJECT_NAME}-backups"
  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "PERSISTENT-DOWN: no $bucket bucket - nothing to empty."
    return 0
  fi
  echo "PERSISTENT-DOWN: emptying $bucket - every PostgreSQL backup is destroyed."
  aws s3 rm "s3://$bucket" --recursive
}
```

Call it from the civo branch only, after the confirmation and before the `persistent-civo` destroy.

- [ ] **Step 9: Apply and verify against the real account**

```bash
PROVIDER=civo make persistent-up
aws s3api head-bucket --bucket vk-civo-lab-backups && echo BUCKET-OK
aws ssm get-parameter --name /vk-civo-lab/persistent-civo/backups/bucket_name \
  --region eu-west-1 --query Parameter.Value --output text
aws s3api get-bucket-tagging --bucket vk-civo-lab-backups
```

Expected: `BUCKET-OK`; the parameter prints `vk-civo-lab-backups`; the tags include `Lifecycle=persistent`, `Project=vk-civo-lab`, `Scope=platform`, `ManagedBy=terraform`.

- [ ] **Step 10: Commit**

```bash
git add terraform/modules/s3-backups terraform/live/persistent-civo/backups scripts/persistent-down.sh
git commit -m "feat(civo-180): add the per-project PostgreSQL backup bucket"
```

---

### Task 4: The pgbackup Roles Anywhere consumer

**Files:**
- Modify: `terraform/modules/rolesanywhere/main.tf:16-20` and its policy-document block
- Modify: `terraform/modules/rolesanywhere/variables.tf:22-26`

**Interfaces:**
- Consumes: `bucket_arn` shape from Task 3 — `arn:aws:s3:::${project}-backups`.
- Produces: IAM role `${project}-ra-pgbackup`; SSM parameter `/${project}/bootstrap/rolesanywhere/role_arn/pgbackup`; certificate common name `${project}-civo-pgbackup`.

- [ ] **Step 1: Raise the profile's session duration**

The refresher writes credentials into a Secret that the sidecar reads once, so a 1-hour session forces hourly churn. Twelve hours is the Roles Anywhere maximum. The existing sidecars pass `--session-duration 3600` explicitly, so raising the profile's cap does not change their behavior.

In `terraform/modules/rolesanywhere/variables.tf`, change the `session_duration` default from `3600` to `43200` and replace its description with:

```hcl
variable "session_duration" {
  description = "Maximum session length the profile allows, in seconds. The sidecars request 3600 explicitly; the backup credential refresher uses the full window so a Secret rewrite is rare."
  type        = number
  default     = 43200
}
```

- [ ] **Step 2: Add the S3 policy document**

Append to `terraform/modules/rolesanywhere/main.tf`, next to the existing `eso` / `external_dns` / `cert_manager` documents. `AbortMultipartUpload` and `ListBucketMultipartUploads` are needed because barman uploads base backups in parts.

```hcl
data "aws_iam_policy_document" "pgbackup" {
  count = local.create ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
    ]
    resources = ["arn:aws:s3:::${var.project}-backups"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["arn:aws:s3:::${var.project}-backups/*"]
  }
}
```

- [ ] **Step 3: Register the consumer**

In the `local.consumers` map at `terraform/modules/rolesanywhere/main.tf:16-20`:

```hcl
  consumers = local.create ? {
    eso            = data.aws_iam_policy_document.eso.json
    "external-dns" = data.aws_iam_policy_document.external_dns.json
    "cert-manager" = data.aws_iam_policy_document.cert_manager.json
    pgbackup       = data.aws_iam_policy_document.pgbackup[0].json
  } : {}
```

If the neighboring documents use no `count`, drop the `count` and the `[0]` from Step 2 and match their style exactly instead.

- [ ] **Step 4: Validate**

```bash
terraform fmt -recursive -check terraform/modules/rolesanywhere
cd terraform/live/bootstrap/rolesanywhere && terragrunt validate
```

- [ ] **Step 5: Apply and verify**

```bash
PROVIDER=civo make bootstrap-up
aws ssm get-parameter --name /vk-civo-lab/bootstrap/rolesanywhere/role_arn/pgbackup \
  --region eu-west-1 --query Parameter.Value --output text
aws iam get-role-policy --role-name vk-civo-lab-ra-pgbackup --policy-name consumer \
  --query 'PolicyDocument.Statement[].Action' --output json
aws rolesanywhere get-profile --profile-id "$(aws ssm get-parameter \
  --name /vk-civo-lab/bootstrap/rolesanywhere/profile_arn --query Parameter.Value \
  --output text | awk -F/ '{print $NF}')" --region eu-west-1 \
  --query 'profile.durationSeconds'
```

Expected: the role ARN prints; the actions include `s3:AbortMultipartUpload`; the profile duration is `43200`.

- [ ] **Step 6: Commit**

```bash
git add terraform/modules/rolesanywhere
git commit -m "feat(civo-180): add the pgbackup Roles Anywhere consumer and S3 policy"
```

---

### Task 5: Wire the new values through argo-up

`scripts/argo-up.sh:82-84` states the SSM name array is at the 10-name batch cap and the next value must split it. This task adds two values, so the split happens here.

**Files:**
- Modify: `scripts/argo-up.sh:80-129` and `scripts/argo-up.sh:403-421`
- Modify: `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`

**Interfaces:**
- Consumes: SSM parameters from Tasks 3 and 4.
- Produces: Helm values `postgres.backup.enabled` (bool), `postgres.backup.bucket` (string), `postgres.backup.schedule` (string), `postgres.backup.retention` (string), `postgres.backup.refreshSchedule` (string), `postgres.backup.image` (string), `awsIdentity.rolesAnywhere.roleArns.pgbackup` (string).

- [ ] **Step 1: Add the defaults to `gitops/values.yaml`**

Under the existing `postgres:` block, add:

```yaml
  # civo-only. The barman-cloud plugin's retentionPolicy accepts a recovery
  # window only, so "2d" with a daily schedule keeps roughly two base backups,
  # not exactly two.
  backup:
    enabled: false
    bucket: ""
    schedule: "0 0 3 * * *"
    retention: "2d"
    refreshSchedule: "0 */8 * * *"
    image: ""
```

Note the schedule has six fields. CloudNativePG's `ScheduledBackup` uses a seconds-first cron spec, unlike a Kubernetes `CronJob`. `refreshSchedule` is a plain `CronJob` schedule and has five.

Add `pgbackup: ""` to `awsIdentity.rolesAnywhere.roleArns`.

- [ ] **Step 2: Mirror the defaults in `gitops/bootstrap/values.yaml`**

Add the same `postgres.backup` block and the `pgbackup` ARN key. The file's own comment says its defaults match `gitops/values.yaml`.

- [ ] **Step 3: Pass them through the root Application**

In `gitops/bootstrap/templates/root-application.yaml`, extend the `helm.parameters` list beside the existing five ARN entries. Hyphenated keys already use the `index` form; `pgbackup` has no hyphen.

```yaml
        - name: awsIdentity.rolesAnywhere.roleArns.pgbackup
          value: {{ .Values.awsIdentity.rolesAnywhere.roleArns.pgbackup | quote }}
        - name: postgres.backup.enabled
          value: {{ .Values.postgres.backup.enabled | quote }}
        - name: postgres.backup.bucket
          value: {{ .Values.postgres.backup.bucket | quote }}
        - name: postgres.backup.schedule
          value: {{ .Values.postgres.backup.schedule | quote }}
        - name: postgres.backup.retention
          value: {{ .Values.postgres.backup.retention | quote }}
        - name: postgres.backup.refreshSchedule
          value: {{ .Values.postgres.backup.refreshSchedule | quote }}
        - name: postgres.backup.image
          value: {{ .Values.postgres.backup.image | quote }}
```

- [ ] **Step 4: Split the SSM batch in `scripts/argo-up.sh`**

Replace the single `civo_ssm_names` array and its one `aws ssm get-parameters` call with two batches, and replace the batch comment at lines 82-84 with one that states the real cap.

```bash
  # aws ssm get-parameters accepts 10 names per call, so the list is fetched
  # in batches rather than one request.
  local civo_ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/bootstrap/route53/zone_id"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-civo/reserved-ip/address"
    "/$PROJECT_NAME/persistent-civo/backups/bucket_name"
    "/$PROJECT_NAME/cluster-civo/network/lb_firewall_id"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/cert-manager"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/pgbackup"
  )
  local civo_ssm_batch_names=() civo_ssm_batch_values=()
  local batch_start=0
  while [ "$batch_start" -lt "${#civo_ssm_names[@]}" ]; do
    while IFS=$'\t' read -r name value; do
      civo_ssm_batch_names+=("$name")
      civo_ssm_batch_values+=("$value")
    done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
      --names "${civo_ssm_names[@]:$batch_start:10}" \
      --query 'Parameters[].[Name,Value]' --output text)
    batch_start=$((batch_start + 10))
  done
```

The existing per-name lookup loop below this needs no change. Add two `case` arms beside the others:

```bash
      */backups/bucket_name) BACKUP_BUCKET="$found" ;;
      */rolesanywhere/role_arn/pgbackup) PGBACKUP_ROLE_ARN="$found" ;;
```

- [ ] **Step 5: Pass the values at install time**

In `civo_install_root_application()`, beside the existing `--set awsIdentity.rolesAnywhere.*` lines:

```bash
    --set awsIdentity.rolesAnywhere.roleArns.pgbackup="$PGBACKUP_ROLE_ARN" \
    --set postgres.backup.enabled=true \
    --set postgres.backup.bucket="$BACKUP_BUCKET" \
    --set postgres.backup.image="$PG_BACKUP_IMAGE" \
```

Near the other configurable defaults at the top of the script (around line 27), add:

```bash
PG_BACKUP_IMAGE="${PG_BACKUP_IMAGE:-}"
```

Leave it empty for now. Task 7 fills in the digest, and Task 8's template fails loudly when it is empty.

- [ ] **Step 6: Verify the AWS render is unchanged**

```bash
make gitops-check
```

Expected: PASS with an empty golden diff. The new values default to `enabled: false`, so no AWS object changes. If the diff is not empty, the new keys leaked into an ungated template — fix that before continuing.

- [ ] **Step 7: Verify the script still parses**

```bash
bash -n scripts/argo-up.sh && shellcheck scripts/argo-up.sh
```

- [ ] **Step 8: Commit**

```bash
git add scripts/argo-up.sh gitops/values.yaml gitops/bootstrap
git commit -m "feat(civo-180): wire backup bucket and pgbackup role into the root Application"
```

---

### Task 6: Issue the pgbackup workload certificate

**Files:**
- Modify: `gitops/values.yaml` (`civoIdentity.consumers`)

**Interfaces:**
- Consumes: the common-name convention `${project}-civo-${name}` enforced by the Terraform trust policy from Task 4.
- Produces: Secret `pgbackup-ra-cert` in namespace `cnpg-system`, holding `tls.crt` and `tls.key`.

- [ ] **Step 1: Add the consumer**

In `gitops/values.yaml`, append to `civoIdentity.consumers`:

```yaml
    - name: pgbackup
      namespace: cnpg-system
```

`gitops/templates/platform/civo/identity/certificates.yaml` ranges over this list, so no template change is needed. The rendered `Certificate` gets `commonName: vk-civo-lab-civo-pgbackup`, `secretName: pgbackup-ra-cert`, 24 h duration, 8 h `renewBefore`, ECDSA-256 with `rotationPolicy: Always`, issued by the `civo-workload-ca` ClusterIssuer at sync-wave 1.

- [ ] **Step 2: Confirm the render**

```bash
helm template ./gitops --set target=civo --set envoyGateway.fqdn=lab.example.com \
  --set envoyGateway.reservedIp=1.2.3.4 --set envoyGateway.firewallId=fw-dummy \
  | yq 'select(.kind=="Certificate" and .metadata.name=="pgbackup")'
```

Expected: a `Certificate` in `cnpg-system` with `commonName: vk-lab-platform-civo-pgbackup` (the default project in a bare `helm template`) and `secretName: pgbackup-ra-cert`.

- [ ] **Step 3: Confirm the AWS render is unchanged**

```bash
make gitops-check
```

Expected: PASS. `civoIdentity` renders only on the Civo target.

- [ ] **Step 4: Commit**

```bash
git add gitops/values.yaml
git commit -m "feat(civo-180): issue the pgbackup workload certificate"
```

---

### Task 7: The credential-refresher image

**Files:**
- Create: `images/aws-session-credentials/Dockerfile`
- Create: `images/aws-session-credentials/refresh.sh`
- Create: `.github/workflows/images.yml`

**Interfaces:**
- Produces: image `ghcr.io/<owner>/<repo>/aws-session-credentials`, referenced by digest in `PG_BACKUP_IMAGE`. Its entrypoint is `/usr/local/bin/refresh.sh`, which reads the environment variables `TRUST_ANCHOR_ARN`, `PROFILE_ARN`, `ROLE_ARN`, `SESSION_DURATION`, `TARGET_SECRET`, `TARGET_NAMESPACE` and writes Secret keys `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SESSION_TOKEN`, `EXPIRATION`.

- [ ] **Step 1: Write the refresh script**

`images/aws-session-credentials/refresh.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${TRUST_ANCHOR_ARN:?}"
: "${PROFILE_ARN:?}"
: "${ROLE_ARN:?}"
: "${TARGET_SECRET:?}"
: "${TARGET_NAMESPACE:?}"
SESSION_DURATION="${SESSION_DURATION:-43200}"
CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-120}"

# The certificate arrives from cert-manager, whose readiness no Argo sync wave
# gates. Exit non-zero when it never shows so the sync retries.
deadline=$((SECONDS + CERT_WAIT_SECONDS))
while [ ! -s /ra/tls.crt ] || [ ! -s /ra/tls.key ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "REFRESH: /ra/tls.crt not present after ${CERT_WAIT_SECONDS}s" >&2
    exit 1
  fi
  sleep 5
done

creds="$(/usr/local/bin/aws_signing_helper credential-process \
  --certificate /ra/tls.crt \
  --private-key /ra/tls.key \
  --trust-anchor-arn "$TRUST_ANCHOR_ARN" \
  --profile-arn "$PROFILE_ARN" \
  --role-arn "$ROLE_ARN" \
  --session-duration "$SESSION_DURATION")"

access_key="$(printf '%s' "$creds" | jq -er '.AccessKeyId')"
secret_key="$(printf '%s' "$creds" | jq -er '.SecretAccessKey')"
session_token="$(printf '%s' "$creds" | jq -er '.SessionToken')"
expiration="$(printf '%s' "$creds" | jq -er '.Expiration')"

kubectl -n "$TARGET_NAMESPACE" create secret generic "$TARGET_SECRET" \
  --from-literal=ACCESS_KEY_ID="$access_key" \
  --from-literal=SECRET_ACCESS_KEY="$secret_key" \
  --from-literal=SESSION_TOKEN="$session_token" \
  --from-literal=EXPIRATION="$expiration" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "REFRESH: wrote $TARGET_NAMESPACE/$TARGET_SECRET, valid until $expiration"

# Environment variables do not change in a running container, so the barman
# sidecar keeps the previous credentials until its pod restarts.
if [ "${RESTART_INSTANCES:-0}" = "1" ]; then
  kubectl -n "$TARGET_NAMESPACE" delete pod -l cnpg.io/cluster=lab-postgres --wait=false
fi
```

`jq -e` makes a missing field a non-zero exit instead of the string `null` reaching the Secret.

`RESTART_INSTANCES` stays in the image from the start, switched off by default. Task 1 decided whether it is used: with `REFRESH_MODE=rollout` the operator restarts the instance itself and the variable stays `0`; with `REFRESH_MODE=long-session` Task 8 sets it to `1`. Building it in now means the image is built and pinned once.

- [ ] **Step 2: Write the Dockerfile**

`images/aws-session-credentials/Dockerfile`. Pin every version; verify the helper's checksum.

```dockerfile
FROM debian:12-slim

ARG SIGNING_HELPER_VERSION=1.8.5
ARG SIGNING_HELPER_SHA256=<fill-from-release-page>
ARG KUBECTL_VERSION=v1.31.0

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl jq; \
    curl -fsSL -o /usr/local/bin/aws_signing_helper \
      "https://rolesanywhere.amazonaws.com/releases/${SIGNING_HELPER_VERSION}/X86_64/Linux/aws_signing_helper"; \
    echo "${SIGNING_HELPER_SHA256}  /usr/local/bin/aws_signing_helper" | sha256sum -c -; \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    curl -fsSL -o /tmp/kubectl.sha256 \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/aws_signing_helper /usr/local/bin/kubectl; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/* /tmp/kubectl.sha256

COPY refresh.sh /usr/local/bin/refresh.sh
RUN chmod 0755 /usr/local/bin/refresh.sh

USER 65532:65532
ENTRYPOINT ["/usr/local/bin/refresh.sh"]
```

Fill `SIGNING_HELPER_SHA256` from the checksum the Roles Anywhere release page publishes for 1.8.5 Linux X86_64. Do not guess it. The build fails loudly if it is wrong, which is the intent.

- [ ] **Step 3: Build locally and confirm the binaries run**

```bash
docker build -t aws-session-credentials:dev images/aws-session-credentials
docker run --rm --entrypoint /usr/local/bin/aws_signing_helper \
  aws-session-credentials:dev --version
docker run --rm --entrypoint kubectl aws-session-credentials:dev version --client
docker run --rm --entrypoint sh aws-session-credentials:dev -c 'id -u'
```

Expected: a version string from each; `id -u` prints `65532`.

- [ ] **Step 4: Confirm the script fails closed on missing inputs**

```bash
docker run --rm aws-session-credentials:dev; echo "exit=$?"
```

Expected: a `TRUST_ANCHOR_ARN: parameter null or not set` message and `exit=1`.

- [ ] **Step 5: Write the build workflow**

`.github/workflows/images.yml`:

```yaml
name: images

on:
  push:
    branches: [main]
    paths:
      - "images/**"
      - ".github/workflows/images.yml"
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  aws-session-credentials:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: build
        uses: docker/build-push-action@v6
        with:
          context: images/aws-session-credentials
          push: true
          tags: ghcr.io/${{ github.repository }}/aws-session-credentials:${{ github.sha }}
      - run: |
          echo "digest: ghcr.io/${{ github.repository }}/aws-session-credentials@${{ steps.build.outputs.digest }}"
```

- [ ] **Step 6: Validate the workflow**

```bash
make validate-actions 2>/dev/null || actionlint .github/workflows/images.yml
```

- [ ] **Step 7: Push, then record the digest**

Merge the branch, let the workflow run, then copy the printed digest into the `PG_BACKUP_IMAGE` default in `scripts/argo-up.sh`:

```bash
PG_BACKUP_IMAGE="${PG_BACKUP_IMAGE:-ghcr.io/<owner>/<repo>/aws-session-credentials@sha256:<digest>}"
```

Confirm it is reachable:

```bash
docker manifest inspect ghcr.io/<owner>/<repo>/aws-session-credentials@sha256:<digest>
```

- [ ] **Step 8: Commit**

```bash
git add images .github/workflows/images.yml scripts/argo-up.sh
git commit -m "feat(civo-180): build the Roles Anywhere credential-refresher image"
```

---

### Task 8: The refresher CronJob and its RBAC

**Files:**
- Create: `gitops/templates/platform/civo/postgres/backup-credentials.yaml`

**Interfaces:**
- Consumes: Secret `pgbackup-ra-cert` (Task 6); values `postgres.backup.*` and `awsIdentity.rolesAnywhere.*` (Task 5); the image from Task 7.
- Produces: Secret `pgbackup-s3-credentials` in `cnpg-system` with keys `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `SESSION_TOKEN` — consumed by Task 9's `ObjectStore`.

The `CronJob` keeps the Secret fresh, but a `CronJob` does not fire when it is created. Without a second path the Secret does not exist until the next schedule boundary, and three things break at bring-up: the `ObjectStore` at wave 2 references a missing Secret, WAL archiving fails from the first minute, and the recovery bootstrap at wave 3 cannot read S3 at all. A `Sync` hook Job mints the Secret before the Cluster syncs; the `CronJob` takes over afterwards.

- [ ] **Step 1: Write the manifest**

```yaml
{{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled }}
{{- if not .Values.postgres.backup.image }}
{{- fail "postgres.backup.image must be set when postgres.backup.enabled is true" }}
{{- end }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pgbackup-credentials
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pgbackup-credentials
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch", "update"]
    resourceNames: ["pgbackup-s3-credentials"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["list", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pgbackup-credentials
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pgbackup-credentials
subjects:
  - kind: ServiceAccount
    name: pgbackup-credentials
    namespace: cnpg-system
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pgbackup-credentials
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  schedule: {{ .Values.postgres.backup.refreshSchedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 600
  jobTemplate:
    spec:
      backoffLimit: 3
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: pgbackup-credentials
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
          containers:
            - name: refresh
              image: {{ .Values.postgres.backup.image | quote }}
              env:
                - name: TRUST_ANCHOR_ARN
                  value: {{ .Values.awsIdentity.rolesAnywhere.trustAnchorArn | quote }}
                - name: PROFILE_ARN
                  value: {{ .Values.awsIdentity.rolesAnywhere.profileArn | quote }}
                - name: ROLE_ARN
                  value: {{ .Values.awsIdentity.rolesAnywhere.roleArns.pgbackup | quote }}
                - name: SESSION_DURATION
                  value: "43200"
                - name: TARGET_SECRET
                  value: pgbackup-s3-credentials
                - name: TARGET_NAMESPACE
                  value: cnpg-system
              securityContext:
                readOnlyRootFilesystem: true
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  memory: 64Mi
              volumeMounts:
                - name: ra-cert
                  mountPath: /ra
                  readOnly: true
          volumes:
            - name: ra-cert
              secret:
                secretName: pgbackup-ra-cert
---
apiVersion: batch/v1
kind: Job
metadata:
  name: pgbackup-credentials-bootstrap
  namespace: cnpg-system
  annotations:
    # A CronJob never fires on creation, so the ObjectStore and the Cluster
    # would sync against a Secret that does not exist yet.
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: pgbackup-credentials
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
      containers:
        - name: refresh
          image: {{ .Values.postgres.backup.image | quote }}
          env:
            - name: TRUST_ANCHOR_ARN
              value: {{ .Values.awsIdentity.rolesAnywhere.trustAnchorArn | quote }}
            - name: PROFILE_ARN
              value: {{ .Values.awsIdentity.rolesAnywhere.profileArn | quote }}
            - name: ROLE_ARN
              value: {{ .Values.awsIdentity.rolesAnywhere.roleArns.pgbackup | quote }}
            - name: SESSION_DURATION
              value: "43200"
            - name: TARGET_SECRET
              value: pgbackup-s3-credentials
            - name: TARGET_NAMESPACE
              value: cnpg-system
            - name: CERT_WAIT_SECONDS
              value: "180"
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          volumeMounts:
            - name: ra-cert
              mountPath: /ra
              readOnly: true
      volumes:
        - name: ra-cert
          secret:
            secretName: pgbackup-ra-cert
            optional: true
{{- end }}
```

Three details are load-bearing and each has a precedent in this repository:

- The ServiceAccount, Role and RoleBinding sit at wave `0`, ahead of the hook Job at wave `1`. An object with no explicit wave defaults to `0` and would be created *after* a hook at a lower wave, and the Job's pod then fails looking up its ServiceAccount.
- `hook-delete-policy: BeforeHookCreation` and nothing else. A failed Job persists and a Job spec is immutable, so a retried sync would recreate it into `AlreadyExists`. `HookSucceeded` must never be added: it deletes the hook when the sync completes rather than when the hook does, and a teardown that deletes the Application mid-sync then leaves an unreapable object holding the operation open.
- The hook's certificate volume is `optional: true`. Wave ordering does not gate cert-manager readiness, and a non-optional secret volume leaves the pod stuck in `ContainerCreating`, stalling the sync instead of failing it. The script's certificate wait turns a missing certificate into a clean non-zero exit, which the root Application's existing `syncPolicy.retry` budget re-attempts.

Mount the whole Secret, never with `subPath`: a `subPath` mount does not see a certificate renewal.

- [ ] **Step 2: Apply the spike's REFRESH_MODE decision**

Task 7 already built `RESTART_INSTANCES` into the image, so no rebuild is needed here.

If Task 1 recorded `REFRESH_MODE=long-session`, add one environment entry to the **CronJob** container only — never to the bootstrap hook, which runs before any instance pod exists:

```yaml
                - name: RESTART_INSTANCES
                  value: "1"
```

If Task 1 recorded `REFRESH_MODE=rollout`, add nothing. The operator restarts the instance itself.

- [ ] **Step 3: Confirm the template renders and the AWS diff stays empty**

```bash
helm template ./gitops --set target=civo --set postgres.backup.enabled=true \
  --set postgres.backup.image=example/img:dev --set postgres.backup.bucket=b \
  --set envoyGateway.fqdn=lab.example.com --set envoyGateway.reservedIp=1.2.3.4 \
  --set envoyGateway.firewallId=fw-dummy \
  | yq 'select(.kind=="CronJob")'
make gitops-check
```

Expected: the `CronJob` renders; `gitops-check` passes with an empty diff.

- [ ] **Step 4: Confirm the guard fires**

```bash
helm template ./gitops --set target=civo --set postgres.backup.enabled=true \
  --set envoyGateway.fqdn=lab.example.com --set envoyGateway.reservedIp=1.2.3.4 \
  --set envoyGateway.firewallId=fw-dummy 2>&1 | grep -c 'postgres.backup.image must be set'
```

Expected: `1`.

- [ ] **Step 5: Run it against the real cluster**

```bash
PROVIDER=civo make argo-up
kubectl -n cnpg-system get job pgbackup-credentials-bootstrap
kubectl -n cnpg-system create job --from=cronjob/pgbackup-credentials refresh-manual
kubectl -n cnpg-system wait --for=condition=complete job/refresh-manual --timeout=180s
kubectl -n cnpg-system get secret pgbackup-s3-credentials -o jsonpath='{.data.EXPIRATION}' | base64 -d
```

Expected: the bootstrap hook Job shows `1/1` completions, the manual Job completes, and an expiration timestamp about 12 hours ahead prints. If the Secret already existed before `refresh-manual` ran, the hook did its job.

- [ ] **Step 6: Prove the credentials really carry the pgbackup identity**

```bash
kubectl -n cnpg-system run sts-probe --rm -it --restart=Never \
  --image=amazon/aws-cli:2.17.0 \
  --env=AWS_ACCESS_KEY_ID="$(kubectl -n cnpg-system get secret pgbackup-s3-credentials -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)" \
  --env=AWS_SECRET_ACCESS_KEY="$(kubectl -n cnpg-system get secret pgbackup-s3-credentials -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)" \
  --env=AWS_SESSION_TOKEN="$(kubectl -n cnpg-system get secret pgbackup-s3-credentials -o jsonpath='{.data.SESSION_TOKEN}' | base64 -d)" \
  -- sts get-caller-identity
```

Expected: the `Arn` contains `vk-civo-lab-ra-pgbackup`.

- [ ] **Step 7: Commit**

```bash
git add gitops/templates/platform/civo/postgres/backup-credentials.yaml
git commit -m "feat(civo-180): refresh Roles Anywhere session credentials into a Secret"
```

---

### Task 9: Install the barman-cloud plugin and declare the ObjectStore

**Files:**
- Create: `gitops/templates/platform/civo/postgres/plugin-application.yaml`
- Create: `gitops/templates/platform/civo/postgres/objectstore.yaml`
- Modify: `gitops/templates/platform/shared/postgres/application.yaml` only if Task 1 Step 2 found the operator below 1.26

**Interfaces:**
- Consumes: Secret `pgbackup-s3-credentials` (Task 8); value `postgres.backup.bucket` (Task 5).
- Produces: `ObjectStore/lab-postgres-backups` in `cnpg-system`, referenced by name from Task 10.

- [ ] **Step 1: Write the plugin Application**

The plugin must live in the operator's own namespace. Wave `-1` puts it beside the `cnpg-operator` Application.

```yaml
{{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: plugin-barman-cloud
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    chart: plugin-barman-cloud
    targetRevision: 0.15.0
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
{{- end }}
```

Confirm `0.15.0` is a real chart version before committing:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm search repo cnpg/plugin-barman-cloud --versions | head
```

Use the newest version whose app version is `v0.15.0` or later, and write that exact number.

- [ ] **Step 2: Write the ObjectStore**

```yaml
{{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled }}
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: lab-postgres-backups
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  retentionPolicy: {{ .Values.postgres.backup.retention | quote }}
  configuration:
    destinationPath: {{ printf "s3://%s/" .Values.postgres.backup.bucket | quote }}
    s3Credentials:
      accessKeyId:
        name: pgbackup-s3-credentials
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: pgbackup-s3-credentials
        key: SECRET_ACCESS_KEY
      sessionToken:
        name: pgbackup-s3-credentials
        key: SESSION_TOKEN
      region: {{ .Values.region | quote }}
    wal:
      compression: gzip
    data:
      compression: gzip
  instanceSidecarConfiguration:
    resources:
      requests:
        cpu: 10m
        memory: 64Mi
      limits:
        memory: 192Mi
{{- end }}
```

`SkipDryRunOnMissingResource=true` is required: Argo can report the plugin Application healthy before its CRD is registered.

- [ ] **Step 3: Confirm the fields against the live CRD**

```bash
kubectl explain objectstore.spec.configuration.s3Credentials
kubectl explain objectstore.spec.instanceSidecarConfiguration
```

Expected: `sessionToken` and `region` both exist. If the CRD names them differently, use the CRD's spelling and note the correction in the spike notes.

- [ ] **Step 4: Render and check**

```bash
helm template ./gitops --set target=civo --set postgres.backup.enabled=true \
  --set postgres.backup.image=example/img:dev --set postgres.backup.bucket=vk-civo-lab-backups \
  --set envoyGateway.fqdn=lab.example.com --set envoyGateway.reservedIp=1.2.3.4 \
  --set envoyGateway.firewallId=fw-dummy \
  | yq 'select(.kind=="ObjectStore" or .metadata.name=="plugin-barman-cloud")'
make gitops-check
```

Expected: both objects render with `destinationPath: "s3://vk-civo-lab-backups/"`; `gitops-check` passes.

- [ ] **Step 5: Apply and confirm the plugin is running**

```bash
PROVIDER=civo make argo-up
kubectl -n cnpg-system rollout status deploy/plugin-barman-cloud --timeout=300s
kubectl -n cnpg-system get objectstore lab-postgres-backups
```

- [ ] **Step 6: Commit**

```bash
git add gitops/templates/platform/civo/postgres/plugin-application.yaml \
        gitops/templates/platform/civo/postgres/objectstore.yaml
git commit -m "feat(civo-180): install the barman-cloud plugin and declare the ObjectStore"
```

---

### Task 10: Attach the Cluster, schedule backups, and recover on bring-up

**Files:**
- Modify: `gitops/templates/platform/shared/postgres/cluster.yaml:26-46` and after line 63
- Create: `gitops/templates/platform/civo/postgres/scheduledbackup.yaml`
- Modify: `scripts/lib/provider.sh:99-102` (`civo_recovery_handle`)
- Modify: `gitops/values.yaml` (add `postgres.recoverFromBackup`)

**Interfaces:**
- Consumes: `ObjectStore/lab-postgres-backups` (Task 9).
- Produces: `ScheduledBackup/lab-postgres-daily`; the Cluster's `plugins` block; a Civo recovery bootstrap gated on `postgres.recoverFromBackup`.

- [ ] **Step 1: Add the plugins block to the Cluster**

In `gitops/templates/platform/shared/postgres/cluster.yaml`, after the AWS-only `backup:` block, add:

```yaml
  {{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled }}
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: lab-postgres-backups
  {{- end }}
```

- [ ] **Step 2: Add the Civo recovery bootstrap**

CloudNativePG recovers into a **new** cluster from an external cluster reference, not in place. Replace the `bootstrap:` block so all three cases are explicit:

```yaml
  bootstrap:
    {{- if and (eq .Values.target "aws") .Values.postgres.recoverySnapshotHandle }}
    recovery:
      database: vkdb
      owner: vkdb
      volumeSnapshots:
        storage:
          apiGroup: snapshot.storage.k8s.io
          kind: VolumeSnapshot
          name: lab-postgres-recovered
    {{- else if and (eq .Values.target "civo") .Values.postgres.backup.enabled .Values.postgres.recoverFromBackup }}
    recovery:
      database: vkdb
      owner: vkdb
      source: backup-store
    {{- else }}
    initdb:
      database: vkdb
      owner: vkdb
    {{- end }}
  {{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled .Values.postgres.recoverFromBackup }}
  externalClusters:
    - name: backup-store
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: lab-postgres-backups
          serverName: lab-postgres
  {{- end }}
```

Keep the existing comment above the AWS branch: a loud failure beats silently wiping a recoverable database.

- [ ] **Step 3: Add the value and resolve it at bring-up**

In `gitops/values.yaml` and `gitops/bootstrap/values.yaml`, add `recoverFromBackup: false` under `postgres:`, and add the matching `helm.parameters` entry in `gitops/bootstrap/templates/root-application.yaml`.

Replace `civo_recovery_handle()` in `scripts/lib/provider.sh:99-102` with a probe that answers "does a base backup exist for this server":

```bash
# Empty means "bootstrap fresh". A probe failure aborts rather than silently
# initdb-ing over a recoverable database.
civo_recovery_handle() {
  local bucket="${PROJECT_NAME}-backups"
  if ! aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    printf 'false'
    return 0
  fi
  local found
  if ! found="$(aws s3 ls "s3://$bucket/lab-postgres/base/" 2>/dev/null | head -n 1)"; then
    printf 'false'
    return 0
  fi
  if [ -n "$found" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}
```

In `scripts/argo-up.sh`, the civo branch already calls `civo_recovery_handle`. Change the assignment to feed the new value and pass it:

```bash
  RECOVER_FROM_BACKUP="$(civo_recovery_handle)"
```

and in `civo_install_root_application()`:

```bash
    --set postgres.recoverFromBackup="$RECOVER_FROM_BACKUP" \
```

Confirm the exact S3 prefix against Task 1's spike notes before writing `lab-postgres/base/`. Barman's layout depends on the `serverName`.

The archiving side leaves `serverName` unset, so it defaults to the cluster name, `lab-postgres` — the same prefix the recovery reads from. Barman resolves this through timelines, but a recovered cluster that archives into the prefix it just recovered from is the hazard to watch. Task 13 runs a second cycle to test exactly that. If it breaks, give the recovered cluster a distinct `serverName` under `plugins[].parameters` and keep `externalClusters[].parameters.serverName` pointing at the old one.

- [ ] **Step 4: Write the ScheduledBackup**

```yaml
{{- if and (eq .Values.target "civo") .Values.postgres.backup.enabled }}
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: lab-postgres-daily
  namespace: cnpg-system
  annotations:
    argocd.argoproj.io/sync-wave: "4"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  schedule: {{ .Values.postgres.backup.schedule | quote }}
  immediate: true
  backupOwnerReference: self
  cluster:
    name: lab-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
{{- end }}
```

`immediate: true` makes the first base backup happen at bring-up rather than at 03:00, so a same-day teardown still has something to restore from. The schedule is a six-field, seconds-first cron spec.

- [ ] **Step 5: Render and check**

```bash
helm template ./gitops --set target=civo --set postgres.backup.enabled=true \
  --set postgres.backup.image=example/img:dev --set postgres.backup.bucket=b \
  --set postgres.recoverFromBackup=true \
  --set envoyGateway.fqdn=lab.example.com --set envoyGateway.reservedIp=1.2.3.4 \
  --set envoyGateway.firewallId=fw-dummy \
  | yq 'select(.kind=="Cluster" or .kind=="ScheduledBackup")'
make gitops-check
bash -n scripts/argo-up.sh scripts/lib/provider.sh && shellcheck scripts/argo-up.sh scripts/lib/provider.sh
```

Expected: the Cluster carries both `plugins` and `externalClusters`; the `ScheduledBackup` renders; `gitops-check` passes with an empty AWS diff.

- [ ] **Step 6: Prove a real backup lands**

```bash
PROVIDER=civo make argo-up
kubectl -n cnpg-system get pod lab-postgres-1 -o jsonpath='{.spec.containers[*].name}'; echo
kubectl -n cnpg-system get scheduledbackup lab-postgres-daily
kubectl -n cnpg-system get backup
aws s3 ls s3://vk-civo-lab-backups/ --recursive | head -20
```

Expected: a barman sidecar container is present; a `Backup` reaches `completed`; objects appear under `lab-postgres/base/` and `lab-postgres/wals/`.

- [ ] **Step 7: Commit**

```bash
git add gitops scripts
git commit -m "feat(civo-180): back up and recover the Civo Postgres cluster through the plugin"
```

---

### Task 11: The pre-teardown backup, and removing the data-loss flag

The operator decided that teardown never needs a confirmation to discard data. `CI_TEARDOWN_ALLOW_DATA_LOSS` therefore leaves the repository entirely, and the teardown backup becomes best-effort: it runs, it is waited for, and a failure is loud but not fatal.

This relaxes constitution §4 ("shutdown MUST fail safely if persistence invariants are not satisfied"). Constitution §13 requires that conflict to be written down, so Step 6 records it.

**Files:**
- Modify: `scripts/lib/provider.sh:104-120` (`civo_backup`)
- Modify: `specs/civo/115-cnpg-cluster-on-civo/spec.md`, `specs/civo/120-cnpg-on-civo-persistence/spec.md`, `specs/civo/140-ci-workflow-civo/spec.md`, `specs/civo/180-cnpg-backups-object-store/spec.md`
- Modify: `specs/hetzner/{016-non-aws-generalisation,115-cnpg-cluster-on-hetzner,120-cnpg-on-hetzner-persistence,140-ci-workflow-hetzner}/spec.md`
- Modify: `docs/architecture.md:550`
- Modify: `docs/adr/0032-cnpg-barman-plugin-physical-backups.md` (add the §4 relaxation to its Consequences)

**Interfaces:**
- Produces: a `civo_backup` with the same name, the same zero-argument signature and the same call site (`scripts/argo-down.sh:45`). It always returns `0`.

- [ ] **Step 1: Replace the refusal stub**

```bash
# Best-effort: forces a base backup before the cascade removes the cluster and
# its volume. A failure is reported loudly but never blocks the teardown.
civo_backup() {
  if ! kubectl get clusters.postgresql.cnpg.io -n cnpg-system lab-postgres >/dev/null 2>&1; then
    echo "ARGO-DOWN: no lab-postgres Cluster on civo - nothing to back up."
    return 0
  fi

  local backup_name="lab-postgres-teardown-$(date +%s 2>/dev/null || echo manual)"
  echo "ARGO-DOWN: forcing a pre-teardown Postgres base backup ($backup_name)..."
  if ! cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup_name
  namespace: cnpg-system
spec:
  cluster:
    name: lab-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  then
    echo "ARGO-DOWN: WARNING - could not create the pre-teardown Backup object. Continuing; Postgres data will be lost." >&2
    return 0
  fi

  local deadline=$((SECONDS + ${ARGO_DOWN_BACKUP_TIMEOUT_SECONDS:-900}))
  local phase=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    phase="$(kubectl -n cnpg-system get backup "$backup_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
    echo "ARGO-DOWN: backup phase: ${phase:-pending}"
    [ "$phase" = "completed" ] && { echo "ARGO-DOWN: backup completed."; return 0; }
    [ "$phase" = "failed" ] && break
    sleep "${POLL_INTERVAL:-5}"
  done

  echo "ARGO-DOWN: WARNING - the pre-teardown backup did not complete (phase '${phase:-timeout}')." >&2
  echo "ARGO-DOWN: WARNING - continuing anyway; everything written since the last good backup is lost." >&2
  echo "ARGO-DOWN: inspect with: kubectl -n cnpg-system describe backup $backup_name" >&2
  return 0
}
```

- [ ] **Step 2: Remove every remaining reference to the flag**

```bash
grep -rn "CI_TEARDOWN_ALLOW_DATA_LOSS" --exclude-dir=.git .
```

Edit each hit so the sentence still reads correctly — do not simply delete the variable name and leave a broken clause. The known hits and what each becomes:

| File | Change |
|---|---|
| `scripts/lib/provider.sh:110-115` | Already gone after Step 1. |
| `specs/civo/115-cnpg-cluster-on-civo/spec.md:28,87,93,97,110,112,221` | Replace the "required for every Civo teardown" wording with "a Civo teardown discards the database without asking"; delete the two acceptance criteria that assert the refusal and the override. |
| `specs/civo/120-cnpg-on-civo-persistence/spec.md:56` | The gate warns and proceeds. |
| `specs/civo/140-ci-workflow-civo/spec.md:56` | The cleanup step runs plain `make down`; drop the "prevents the fail-closed CNPG rule leaving a billing cluster behind" clause, which no longer applies. |
| `specs/civo/180-cnpg-backups-object-store/spec.md:65` | Rewritten wholesale by Task 2. Confirm no reference survives. |
| `specs/hetzner/016,115,120,140` | Same treatment. These are DRAFT/READY planning specs on another provider; keep the edits minimal and factual. |
| `docs/architecture.md:550` | State that a Civo teardown backs up best-effort and then discards. |
| `docs/superpowers/plans/2026-09-11-civo-115-*.md` | Leave untouched. A completed plan is a historical record. |

- [ ] **Step 3: Verify the flag is gone**

```bash
grep -rn "CI_TEARDOWN_ALLOW_DATA_LOSS" --exclude-dir=.git . \
  | grep -v 'docs/superpowers/plans/2026-09-11-civo-115'
echo "remaining=$?"
```

Expected: `remaining=1`, meaning grep found nothing outside the historical plan.

- [ ] **Step 4: Verify the script parses**

```bash
bash -n scripts/lib/provider.sh && shellcheck scripts/lib/provider.sh
```

- [ ] **Step 5: Prove teardown proceeds when the backup fails**

Point the object store at a bucket that does not exist, then tear down.

```bash
kubectl -n cnpg-system patch objectstore lab-postgres-backups --type merge \
  -p '{"spec":{"configuration":{"destinationPath":"s3://vk-civo-lab-backups-does-not-exist/"}}}'
ARGO_DOWN_BACKUP_TIMEOUT_SECONDS=180 PROVIDER=civo ./scripts/argo-down.sh; echo "exit=$?"
```

Expected: `exit=0`; the two `WARNING` lines appear on stderr; the teardown continues to the cascade. Confirm the cluster really went:

```bash
kubectl -n cnpg-system get cluster lab-postgres; echo "lookup exit=$?"
```

Expected: `lookup exit=1` — not found.

Then run `PROVIDER=civo make up` to restore the environment for Task 12.

- [ ] **Step 6: Record the constitution conflict**

Append to the Consequences of `docs/adr/0032-cnpg-barman-plugin-physical-backups.md`:

```markdown
- Constitution §4's "shutdown MUST fail safely if persistence invariants are
  not satisfied" is relaxed for the Civo target. A teardown makes one
  best-effort base backup, reports a failure loudly, and then proceeds. The
  operator chose this deliberately: an unattended lab must never leave a
  billing cluster behind because a backup failed, and the daily schedule plus
  the recovery window already bound the loss. Reinstating a blocking gate needs
  a new ADR, not an amendment.
```

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/provider.sh specs docs
git commit -m "feat(civo-180): back up best-effort at teardown and drop the data-loss flag"
```

---

### Task 12: Extend the render check and the e2e suite

**Files:**
- Modify: `scripts/gitops-render-check.sh:63-71` (`REQUIRED_OBJECTS_CIVO`)
- Modify: `tests/e2e/postgres_test.go`

**Interfaces:**
- Consumes: every object created in Tasks 6, 8, 9 and 10.

- [ ] **Step 1: Require the new Civo objects**

`scripts/gitops-render-check.sh` renders Civo without `--set postgres.backup.enabled=true`, so it must pass that flag for these objects to appear. Civo and local are rendered together in a loop at `scripts/gitops-render-check.sh:121-125`, so the flags belong inside that loop, applied to `civo` only:

```bash
CIVO_LOCAL_OK=true
for t in civo local; do
  extra_sets=()
  if [ "$t" = civo ]; then
    extra_sets=(--set postgres.backup.enabled=true
                --set postgres.backup.bucket=render-check-bucket
                --set postgres.backup.image=render-check/image:dev)
  fi
  render_and_normalize "$REPO_ROOT/gitops" "$STRUCT_DIR/$t" "$t" "${extra_sets[@]}"
  verify_object_set "$STRUCT_DIR/$t" "$t" || CIVO_LOCAL_OK=false
done
```

`render_and_normalize` already forwards its extra arguments to `helm template`. Read lines 121-125 before editing and keep the surrounding style. Then append to `REQUIRED_OBJECTS_CIVO`:

```
Certificate__cnpg-system__pgbackup CronJob__cnpg-system__pgbackup-credentials \
ObjectStore__cnpg-system__lab-postgres-backups \
ScheduledBackup__cnpg-system__lab-postgres-daily \
Job__cnpg-system__pgbackup-credentials-bootstrap \
Application__argocd__plugin-barman-cloud
```

- [ ] **Step 2: Run it**

```bash
make gitops-check
```

Expected: PASS. The AWS golden diff must still be empty — if it is not, a new template is missing its `eq .Values.target "civo"` guard.

- [ ] **Step 3: Add the e2e assertions**

`tests/e2e/postgres_test.go` already asserts the `lab-postgres` cluster and the `lab-postgres-app` Secret. Add a Civo-only test using the same client and namespace constants the file already defines:

```go
func TestPostgresBackupCredentialsExist(t *testing.T) {
	if os.Getenv("PROVIDER") != "civo" {
		t.Skip("backup credentials are civo-only")
	}
	ctx := context.Background()
	_, err := clientset.CoreV1().Secrets(postgresNamespace).
		Get(ctx, "pgbackup-s3-credentials", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("pgbackup-s3-credentials secret missing: %v", err)
	}
}
```

Match the file's existing client variable and namespace constant names rather than inventing new ones. The e2e role is read-only and already has `secrets` read access in `cnpg-system` through `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml`.

- [ ] **Step 4: Run the tests**

```bash
gofmt -l tests/e2e
PROVIDER=civo make test-postgres
```

Expected: `gofmt` prints nothing; the tests pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/gitops-render-check.sh tests/e2e/postgres_test.go
git commit -m "test(civo-180): assert the backup objects render and the credential Secret exists"
```

---

### Task 13: Full-cycle validation on a real Civo cluster

This is the acceptance evidence. Every earlier task is a component test; this is the only proof the mechanism works.

**Files:**
- Create: `tests/manual/180-cnpg-barman-backups.md`

- [ ] **Step 1: Bring up and write known data**

```bash
PROVIDER=civo make up
kubectl -n cnpg-system exec -it lab-postgres-1 -c postgres -- \
  psql -U postgres -d vkdb -c \
  "CREATE TABLE backup_proof(id serial primary key, note text); \
   INSERT INTO backup_proof(note) VALUES ('written before teardown');"
kubectl -n cnpg-system exec -it lab-postgres-1 -c postgres -- \
  psql -U postgres -d vkdb -c "SELECT count(*) FROM backup_proof;"
```

Record the count.

- [ ] **Step 2: Confirm WAL archiving is live**

```bash
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'; echo
aws s3 ls s3://vk-civo-lab-backups/lab-postgres/wals/ --recursive | tail -5
```

Expected: the condition is `True`; WAL objects are present and recent.

- [ ] **Step 3: Tear down and confirm the gate ran**

```bash
PROVIDER=civo make down
```

Expected: the pre-teardown backup message appears and reaches `completed`, with no `WARNING` line. `make down` exits `0`.

- [ ] **Step 4: Confirm the persistent side survived**

```bash
aws s3 ls s3://vk-civo-lab-backups/lab-postgres/base/ | tail -3
civo kubernetes list
```

Expected: base backups are still there; the Civo cluster is gone.

- [ ] **Step 5: Bring up again and confirm the data came back**

```bash
PROVIDER=civo make up
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.status.phase}{"\n"}'
kubectl -n cnpg-system exec -it lab-postgres-1 -c postgres -- \
  psql -U postgres -d vkdb -c "SELECT count(*), max(note) FROM backup_proof;"
```

Expected: the phase is healthy and the count matches Step 1. If the table is missing, the recovery bootstrap did not trigger — check `postgres.recoverFromBackup` in the rendered Cluster and the S3 prefix used by `civo_recovery_handle`.

- [ ] **Step 6: Run a second cycle — recover from a cluster that was itself recovered**

The first cycle recovers from a cluster created by `initdb`. Only a second cycle proves that a recovered cluster archives correctly into the same prefix.

```bash
kubectl -n cnpg-system exec -it lab-postgres-1 -c postgres -- \
  psql -U postgres -d vkdb -c "INSERT INTO backup_proof(note) VALUES ('written in cycle two');"
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'; echo
PROVIDER=civo make down
PROVIDER=civo make up
kubectl -n cnpg-system exec -it lab-postgres-1 -c postgres -- \
  psql -U postgres -d vkdb -c "SELECT count(*) FROM backup_proof;"
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'; echo
```

Expected: the count is Step 1's count plus one, and `ContinuousArchiving` is `True` again. A failure here is the `serverName` collision described in Task 10 Step 3.

- [ ] **Step 7: Confirm the retention window prunes**

```bash
kubectl -n cnpg-system get backup
aws s3 ls s3://vk-civo-lab-backups/lab-postgres/base/
```

Record the count of base backups. With `retentionPolicy: 2d` and a daily schedule, expect about 2 to 3 after three days. Note the observed number and the date in the manual test document rather than asserting an exact figure.

- [ ] **Step 8: Confirm no permanent credential exists**

```bash
grep -rniE 'AKIA[0-9A-Z]{16}' --exclude-dir=.git . ; echo "grep exit=$?"
aws ssm describe-parameters --region eu-west-1 \
  --query "Parameters[?contains(Name,'vk-civo-lab')].[Name,Type]" --output text
kubectl -n cnpg-system get secret pgbackup-s3-credentials \
  -o jsonpath='{.data.EXPIRATION}' | base64 -d; echo
```

Expected: the grep finds nothing (`grep exit=1`); no SSM parameter holds an access key; the Secret's expiration is in the future and moves forward after each refresh.

- [ ] **Step 9: Write the manual test document**

`tests/manual/180-cnpg-barman-backups.md`, in the style of `tests/manual/007-postgres.md`: every command above, the expected output, and the observed results with dates.

- [ ] **Step 10: Mark the spec done**

In `specs/civo/180-cnpg-backups-object-store/spec.md`, set `status: "DONE"` and `completed: "2026-09-15"` (use the real date), tick every §13 checkbox, and add the evidence to §14. Update `specs/civo/README.md` and `specs/civo/roadmap.md` where they list 180's status.

- [ ] **Step 11: Final validation and commit**

```bash
make gitops-check
terraform fmt -recursive -check terraform/
PROVIDER=civo make test
git add tests/manual specs/civo
git commit -m "docs(civo-180): record the full backup and recovery cycle evidence"
```

- [ ] **Step 12: Tear down to stop the spend**

```bash
PROVIDER=civo make down
```

Leave the persistent stack in place. It costs about 0.25 USD per month for the bucket.

---

## Cost

- S3 storage for two base backups plus WAL of a 20 GiB lab database: about 0.25 USD per month.
- Civo egress to S3 is free, so pushing backups out costs nothing on the Civo side.
- IAM Roles Anywhere is free. The extra SSM parameters are Standard tier, so free.
- The Civo cluster itself dominates the validation cost. Three full cycles in Task 13 cost about 0.75 USD.

## Decision record: why this is not presigned URLs

The operator described the design as "presigned S3 URLs plus the CNPG barman plugin". Those two do not compose, for the reasons set out in "Why this replaces the spec as written": barman-cloud needs multi-object S3 access through boto3, a presigned URL grants one object and one method, and the plugin's sidecar can carry no mounted certificate. The plugin is the part the operator named explicitly, so the plugin stays and the credential delivery changes.

What replaces it meets the same intent — no permanent AWS key anywhere. Roles Anywhere session credentials, valid 12 hours, are minted by a job that owns its image and holds a 24-hour workload certificate, then written into a Secret the sidecar reads. Task 2 writes this into ADR 0032 as the decision of record.

Nothing in this plan waits on further confirmation.
