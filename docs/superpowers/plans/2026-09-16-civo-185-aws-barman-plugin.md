# CIVO-185: AWS moves to the CNPG barman-cloud plugin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (or subagent-driven-development). Steps use `- [ ]`.
> First action after approval: copy this file to `docs/superpowers/plans/2026-09-16-civo-185-aws-barman-plugin.md` and commit it on branch `civo-185-foundations`.

**Goal:** AWS PostgreSQL survives `make down`/`make up` through the barman-cloud plugin (S3 + WAL, PITR), with EKS Pod Identity; the EBS `VolumeSnapshot` path is removed without any bring-up running `initdb` over real data.

**Architecture:** Reuse the Civo plugin templates, generation pointer and best-effort teardown. AWS differs only in identity (Pod Identity association on SA `cnpg-system/lab-postgres`, upstream multi-arch sidecar) and SSM layer (`persistent` vs `persistent-civo`). Cutover is additive → dual cycle → removal.

**Tech Stack:** Terraform 1.15.9 / Terragrunt 1.1.x, Helm + Argo CD, CNPG chart 0.29.0 (operator 1.30.0), plugin chart 0.8.0 (v0.15.0), Bash.

**Spec:** `specs/civo/185-P-aws-logical-backup-migration/spec.md`

## Context

The operator chose to build CIVO-185 before the remaining M1 specs (PR #13). AWS today recovers from a cold EBS snapshot taken at teardown (fail-closed, no PITR). Civo already runs the plugin. One mechanism removes the snapshot controller, class, client-side-applied `VolumeSnapshotContent`, the root `ignoreDifferences` entry and the snapshot discovery/prune code.

## Global Constraints

- Region literal `eu-west-1`. `AWS_PROFILE=viacheslav-dev` for every AWS command.
- No AWS access key anywhere (repo, cluster, SSM). Pod Identity on AWS, Roles Anywhere on Civo.
- Never a real root domain; `<root-domain>` placeholders only.
- Terraform owns AWS resources, Argo owns Kubernetes resources. Tags come from `terraform/live/root.hcl` `default_tags`; never per resource.
- Code comments: only where hard, ≤3 lines, never a spec/ADR/ticket reference.
- `CI_TEARDOWN_ALLOW_DATA_LOSS`: already absent from every live contract (only dated DONE records in CIVO-115/120 and ADR 0032 history). Nothing to do; re-grep in Task 12.
- Teardown never blocks on a plugin backup result (constitution §4). The AWS cold snapshot stays fail-closed only while it exists (Phase B).
- No PR CI. Offline checks: `make gitops-check`, `terraform fmt -recursive -check terraform/`, `terragrunt validate`/`plan`, `bash -n`. shellcheck and yamllint are **not installed** — do not use them.
- Goldens regenerate only with `./scripts/gitops-render-check.sh update`, in a separate commit, diff reviewed.
- Pins (verified 2026-09-16):
  - PostgreSQL `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie@sha256:42708a75345b7a48fdd9257b071830783a97fd228529196b6313187a7198e185` (CNPG 1.30.0 default; amd64+arm64).
  - Upstream sidecar `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.15.0@sha256:06c78deca670525daa35fb1e5323159092785d11cf87b86217bdd5c679a41a84` (amd64+arm64; same base as the Civo image).
- Commits end with the harness attribution trailers. Branches: `civo-185-foundations`, `civo-185-additive`, `civo-185-removal`. Merge only on operator approval.

## Deviations from spec §4 (record in spec §14 in Task 11)

- **D1 — `postgres.backup.enabled` stays `false` in `gitops/values.yaml`.** `aws_install_root_application` passes `enabled/bucket/serverName/recoverServerName`, like Civo. Reason: `objectstore.yaml` `fail`s on an empty bucket, which breaks the default aws render.
- **D2 — Sidecar image per target is a values map** `postgres.backup.sidecarImages.{aws,civo}` chosen by `index … .Values.target`, not a runtime `--set` from `civo_install_root_application`. Digests are code constants and stay in Git.
- **D3 — dropped after Gate A.** Planned: region env on AWS. Gate A showed EKS Pod Identity injects `AWS_REGION` and `AWS_DEFAULT_REGION` into the native sidecar, so `Cluster.spec.env` and `projectedVolumeTemplate` stay Civo-only.
- **D5 — `externalClusters` does not render on the AWS snapshot-recovery path.** During the dual cycle a bring-up can have both a snapshot handle and a pointer; the snapshot branch wins and an unreferenced `externalClusters` entry would reach the CNPG webhook untested. The gate excludes that case; it disappears with the snapshot branch in Task 9.
- **D6 — AWS `make up` now requires `persistent/backups` applied.** `aws_resolve_inputs` reads the bucket SSM parameter through the fail-hard `ssm_output`.
- **D4 — `backup_publish_server_name`/`backup_prune_generations` stay in `argo-up.sh`** (they use its globals); `backup_teardown`, `backup_archiving_status`, `backup_recovery_handle` live in `scripts/lib/provider.sh`. `backup_recovery_handle <layer>` returns the previous `serverName` from SSM.

## File map

| Area | Files |
|---|---|
| Exclude list | `Makefile:35,40`, `scripts/lib/provider.sh:17,25`, `scripts/persistent-up-civo.sh:18`, `scripts/persistent-down.sh:167-171` |
| Bucket | `terraform/modules/postgres-backups/{main,variables}.tf`, new `terraform/live/persistent/backups/terragrunt.hcl`, `scripts/persistent-down.sh`, `.github/workflows/lifecycle-test.yml:97-118`, `terraform/live/persistent/README.md` |
| Identity | new `terraform/modules/postgres-backup-pod-identity/{main,variables,outputs,versions}.tf`, new `terraform/live/cluster/postgres-backup-pod-identity/terragrunt.hcl`, `terraform/live/cluster/README.md` |
| GitOps | move `gitops/templates/platform/civo/postgres/{barman-plugin-application,objectstore,scheduled-backup}.yaml` → `platform/shared/postgres/`; `shared/postgres/cluster.yaml`; `gitops/values.yaml`; later delete `aws/postgres/recovered-snapshot.yaml`, `aws/ebs-csi/{snapshot-controller,volumesnapshotclass}.yaml`; `gitops/bootstrap/{values.yaml,templates/root-application.yaml}`; `aws/cert-manager/application.yaml:8-14` comment |
| Render check | `scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/**` |
| Scripts | `scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh` |
| Docs | new `docs/adr/0033-barman-cloud-plugin-backups-on-aws.md`; `docs/adr/0013-*.md`, `docs/adr/0032-*.md` status; constitution §4 L91; `docs/architecture.md:544-553`; `docs/aws-platform-design.md:59-61,96-99,123-125`; `tests/manual/007-postgres.md`; `specs/civo/decisions.md`; `Makefile:139-144`; `lifecycle-test.yml:42,187` |

---

## Phase A — Foundations and spike gates (branch `civo-185-foundations`)

### Task 1: `PERSISTENT_EXCLUDE` becomes a list

Must land before, or in the same PR as, Task 2: on Civo `PROJECT_NAME=vk-civo-lab`, so `persistent/backups` would try to create `vk-civo-lab-postgres-backups`, which `persistent-civo/backups` already owns.

Verified in-session: Terragrunt 1.1.5 `list --filter '!./vpc' --filter '!./secrets'` returns nothing (negations combine), and a filter for a missing unit is not an error.

- [ ] Step 1 (test, fails today for `backups`): `cd terraform/live/persistent && terragrunt list --filter '!./vpc' --filter '!./backups'` → expect `secrets` only.
- [ ] Step 2: `Makefile:35` → `export PERSISTENT_EXCLUDE := vpc backups`; `provider.sh:17` → `${PERSISTENT_EXCLUDE:-vpc backups}`.
- [ ] Step 3: add to `scripts/lib/provider.sh` (after the defaults block):
```bash
# Expands PERSISTENT_EXCLUDE into one negated filter per unit.
persistent_exclude_filters() {
  local unit
  for unit in $PERSISTENT_EXCLUDE; do
    printf -- '--filter\n!./%s\n' "$unit"
  done
}
```
- [ ] Step 4: `persistent-up-civo.sh:18` and `persistent-down.sh:167-171` both become (bash 3.2 safe, no mapfile):
```bash
exclude_args=()
while IFS= read -r arg; do exclude_args+=("$arg"); done < <(persistent_exclude_filters)
terragrunt run --all ${exclude_args[@]+"${exclude_args[@]}"} --non-interactive -- apply -auto-approve
```
  (`destroy` in `persistent-down.sh`; the `if [ -n … ]` branch collapses into this one call.)
- [ ] Step 5: `bash -n` on the three scripts; `PROVIDER=civo bash -c 'source scripts/lib/provider.sh; persistent_exclude_filters'` prints four lines.
- [ ] Step 6: commit `civo-185: PERSISTENT_EXCLUDE accepts a list`.

### Task 2: AWS backup bucket unit and provider-neutral bucket teardown

- [ ] Step 1: `terraform/modules/postgres-backups/variables.tf` add:
```hcl
variable "ssm_layer" {
  description = "Lifecycle directory whose SSM path records the bucket name (persistent or persistent-civo)."
  type        = string
  default     = "persistent-civo"
}
```
  `main.tf:85` → `name = "/${var.project}/${var.ssm_layer}/backups/bucket_name"`.
- [ ] Step 2 (no-change proof): `PROVIDER=civo` env, `cd terraform/live/persistent-civo/backups && terragrunt plan` → `No changes.`
- [ ] Step 3: create `terraform/live/persistent/backups/terragrunt.hcl` (copy of the Civo unit plus `ssm_layer = "persistent"`).
- [ ] Step 4: `cd terraform/live/persistent/backups && terragrunt init && terragrunt validate` — settles whether the module's `civo` required_provider initializes without a generated civo block. If it fails, split `versions.tf` is **not** an option (Civo unit needs it); instead record the error and stop.
- [ ] Step 5: `terragrunt plan` → 6 to add (bucket, SSE, public access block, policy, lifecycle, SSM `/vk-lab-platform/persistent/backups/bucket_name`). `cd terraform/live/persistent && terragrunt list --filter '!./vpc' --filter '!./backups'` (Civo exclude) still returns only `secrets`.
- [ ] Step 6: `scripts/lib/provider.sh` defaults: `export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent-civo}"` (civo) / `persistent` (aws).
- [ ] Step 7: `scripts/persistent-down.sh`: hoist the bucket-emptying block (140-146) out of `if [ -n "$PERSISTENT_EXTRA_DIR" ]` to run before it on both providers; pointer delete becomes `--name "/$PROJECT_NAME/$BACKUP_SSM_LAYER/postgres-backup/server_name"` and also moves out; add `persistent/backups` to the line-173 list.
- [ ] Step 8: `lifecycle-test.yml` add `persistent/backups \` to the validate list; `terraform/live/persistent/README.md` "Two units" → three, add a `backups/` bullet and note Civo excludes it.
- [ ] Step 9: `terraform fmt -recursive -check terraform/`, `bash -n scripts/persistent-down.sh`; commit.

### Task 3: Pod Identity for the Postgres instance pods

- [ ] Step 1: `terraform/modules/postgres-backup-pod-identity/` — `versions.tf` copied from `external-dns-pod-identity`; `variables.tf`: `cluster_name`, `project`, `service_account_name` (default `lab-postgres`), `service_account_namespace` (default `cnpg-system`); `outputs.tf`: `role_arn`; `main.tf`:
```hcl
module "pod_identity" {
  source                    = "../pod-identity"
  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-postgres-backup"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

locals {
  # A literal, not a dependency: the bucket lives in the persistent stack.
  bucket_arn = "arn:aws:s3:::${var.project}-postgres-backups"
}

data "aws_iam_policy_document" "backup" {
  statement {
    sid       = "AllowBackupBucketDiscovery"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "AllowBackupObjectAccess"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "backup" {
  name   = "backup"
  role   = module.pod_identity.role_name
  policy = data.aws_iam_policy_document.backup.json
}
```
- [ ] Step 2: unit `terraform/live/cluster/postgres-backup-pod-identity/terragrunt.hcl` = copy of `external-secrets-pod-identity/terragrunt.hcl` with the new module source.
- [ ] Step 3: `cd terraform/modules/postgres-backup-pod-identity && terraform init -backend=false && terraform validate`; `terraform fmt -check -recursive terraform/`.
- [ ] Step 4: `lifecycle-test.yml:97` "the four" → "the five"; `terraform/live/cluster/README.md` add the unit bullet (and drop the stale `argocd-bootstrap/` bullet, count → current).
- [ ] Step 5: commit; open PR `civo-185-foundations` (Tasks 1–3 + plan file). Merge on approval — no live effect until applied.

### Checkpoint A — apply foundations on AWS (≈40 min, operator runs or approves)

- [ ] `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Project,Values=vk-lab-platform Name=tag:Component,Values=postgres --query 'sort_by(Snapshots,&StartTime)[].[SnapshotId,StartTime,State]' --output text` — record the rollback snapshot.
- [ ] `cd terraform/live/persistent/backups && terragrunt apply` → bucket and SSM exist.
- [ ] `make up` from the branch checkout (gitops still from `main`): data returns from the snapshot; the new pod-identity unit is applied by `cluster-up`'s `run --all`.
- [ ] `aws eks list-pod-identity-associations --cluster-name vk-lab-platform-eks --namespace cnpg-system` shows `lab-postgres`.

### Task 4: Spike Gate A — Pod Identity reaches the native sidecar (live, ≈1 h)

**Files:** none committed except evidence in spec §14.

- [ ] Step 1 — major version guard: `kubectl -n cnpg-system exec lab-postgres-1 -c postgres -- psql -U postgres -tAc 'show server_version_num'` → must start with `18`. Otherwise **stop**: the pin would fail to start the recovered data.
- [ ] Step 2 — observe real Pod Identity injection on a known consumer (copy values verbatim into §14):
  `kubectl -n kube-system get pod -l app.kubernetes.io/name=external-dns -o json | jq '.items[0].spec.containers[0].env, .items[0].spec.volumes'`
- [ ] Step 3 — freeze Argo on the Cluster: `kubectl -n argocd patch application root --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'`.
- [ ] Step 4 — install the plugin by hand: `helm upgrade --install barman-cloud-plugin oci://ghcr.io/cloudnative-pg/charts/plugin-barman-cloud --version 0.8.0 -n cnpg-system --set sidecarImage.tag='v0.15.0@sha256:06c78deca670525daa35fb1e5323159092785d11cf87b86217bdd5c679a41a84' --wait`.
- [ ] Step 5 — apply an `ObjectStore` `lab-postgres-backups` identical to the shared template (bucket `vk-lab-platform-postgres-backups`, `inheritFromIAMRole: true`, gzip, sidecar resources 64Mi/256Mi, retention `2d`).
- [ ] Step 6 — patch the Cluster: `spec.env` = `AWS_REGION`/`AWS_DEFAULT_REGION=eu-west-1`; `spec.plugins` = `barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`, `barmanObjectName: lab-postgres-backups`, `serverName: lab-postgres-spike-<UTC ts>`. Wait for the instance to roll.
- [ ] Step 7 — pass criteria:
  - `kubectl -n cnpg-system get pod lab-postgres-1 -o json | jq '.spec.initContainers[] | select(.name=="plugin-barman-cloud") | {env, volumeMounts}'` contains `AWS_CONTAINER_CREDENTIALS_FULL_URI` and the `eks-pod-identity-token` mount.
  - `kubectl -n cnpg-system get cluster lab-postgres -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}'` → `True`.
  - `aws s3 ls s3://vk-lab-platform-postgres-backups/lab-postgres-spike-<ts>/wals/ --recursive | tail -3` shows objects.
- [ ] Step 8 — coexistence (needed for the dual cycle): create a `Backup` `method: plugin`, wait `completed`; then a `Backup` `method: volumeSnapshot`, wait `completed`; `ContinuousArchiving` still `True` afterwards.
- [ ] **Fallback if the webhook skips the init container:** set the env values and a `projectedVolumeTemplate` `serviceAccountToken` source copied from Step 2 on `Cluster.spec` (the sidecar inherits both), re-run Step 7, record the deviation. If archiving still fails → **stop and report**.

### Task 5: Spike Gate B — arm64 base backup and recovery (live, ≈1 h)

- [ ] Step 1: write proof rows: `kubectl -n cnpg-system exec lab-postgres-1 -c postgres -- psql -U postgres -d vkdb -c "CREATE TABLE IF NOT EXISTS civo185_proof(id serial primary key, note text, at timestamptz default now()); INSERT INTO civo185_proof(note) VALUES ('gate-b');"`; record `SELECT count(*)`.
- [ ] Step 2: `Backup` `method: plugin` → `completed`; during it run `kubectl top pod lab-postgres-1 -n cnpg-system --containers` every 10 s; record the sidecar peak. Then `select pg_switch_wal()`.
- [ ] Step 3: temporary identity for the restore job: `aws eks create-pod-identity-association --cluster-name vk-lab-platform-eks --namespace cnpg-system --service-account spike-restore --role-arn <role_arn of postgres-backup unit>`.
- [ ] Step 4: apply Cluster `spike-restore` (instances 1, pinned `imageName`, `affinity.nodeSelector.workload-type: on-demand`, `storage 20Gi ebs-delete`, `env` region, `bootstrap.recovery.source: origin`, `externalClusters[origin].plugin` → `barmanObjectName: lab-postgres-backups`, `serverName: lab-postgres-spike-<ts>`).
- [ ] Step 5 — pass criteria: Cluster healthy; `kubectl get node $(kubectl -n cnpg-system get pod spike-restore-1 -o jsonpath='{.spec.nodeName}') -L kubernetes.io/arch` → `arm64`; `SELECT count(*) FROM civo185_proof` equals Step 1.
- [ ] Step 6 — cleanup: delete Cluster `spike-restore`, delete the temporary association, restore root auto-sync is not needed (teardown disarms anyway). Record memory, arch, counts, timings in spec §14.
- [ ] Step 7: `make down` (main scripts; takes the fail-closed snapshot, which now holds `civo185_proof`). Then `aws s3 rm s3://vk-lab-platform-postgres-backups/lab-postgres-spike-<ts>/ --recursive`.

### ⛔ STOP — report Gates A and B to the operator. Do not start Phase B without both passing and an explicit go.

---

## Phase B — Additive half (branch `civo-185-additive`)

### Task 6: Shared plugin templates, image pins, render check

- [ ] Step 1 — Civo image guard (Civo may be down): read the newest `backup.info` under the current generation: `aws s3 ls s3://vk-civo-lab-postgres-backups/ ` then `aws s3 cp s3://vk-civo-lab-postgres-backups/<gen>/base/<id>/backup.info - | grep '^version'` → must be `18xxxx`. Otherwise **stop**.
- [ ] Step 2 — failing test first, in `scripts/gitops-render-check.sh`:
  - after line 51 add renders `platform-backup` (aws + `postgres.backup.enabled=true`, `bucket=render-check-bucket`, `serverName=render-check-server`) and `platform-backup-recovery` (same + `recoverServerName=render-check-previous`); `platform-recovery` gains the three backup `--set`s (dual-cycle shape).
  - add `verify_backup_render <dir> <target> <expected-sidecar-repo>`: requires `ObjectStore__cnpg-system__lab-postgres-backups`, `ScheduledBackup__cnpg-system__lab-postgres`, `Application__argocd__barman-cloud-plugin`; `yq` asserts the plugin Application's `sidecarImage.repository` parameter equals the expected repo and `Cluster.spec.imageName` equals the pin. Call it for aws `platform-backup` (`cloudnative-pg/plugin-barman-cloud-sidecar`) and civo (`savak1990/vk-lab-platform/cnpg-barman-sidecar`).
  - Run `make gitops-check` → FAIL (aws renders no ObjectStore).
- [ ] Step 3 — `git mv` the three templates to `gitops/templates/platform/shared/postgres/`; gate each on `{{- if and (ne .Values.target "local") .Values.postgres.backup.enabled }}`. In `barman-plugin-application.yaml` use `{{- $sidecar := index .Values.postgres.backup.sidecarImages .Values.target }}` for registry/repository/tag@digest, and change the wave comment to "After cert-manager, whose issuer…" (no wave number).
- [ ] Step 4 — `gitops/values.yaml`: add `postgres.imageName: "ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie@sha256:42708a75…e185"` with a one-line comment ("Pinned so an operator chart upgrade never changes the major under existing data."); replace `sidecarImage` with `sidecarImages.aws` (ghcr.io / `cloudnative-pg/plugin-barman-cloud-sidecar` / `v0.15.0` / `sha256:06c78dec…1a84`) and `sidecarImages.civo` (current values); drop "civo-only." from the backup comment.
- [ ] Step 5 — `cluster.yaml`: add `imageName: {{ .Values.postgres.imageName | quote }}`; bootstrap order: aws snapshot branch (unchanged) → `else if and .Values.postgres.backup.enabled .Values.postgres.backup.recoverServerName` recovery (target test removed) → initdb; `externalClusters` gate drops the civo test; `projectedVolumeTemplate` stays `civo`-gated; `env` + `plugins` render when `backup.enabled`, with `AWS_CONFIG_FILE` inside a nested `civo` gate; the aws `backup.volumeSnapshot` block stays.
- [ ] Step 6 — `make gitops-check` → civo/local structural PASS and new asserts PASS; aws golden diff FAIL (expected). Commit templates.
- [ ] Step 7 — `./scripts/gitops-render-check.sh update`; review `git diff --stat tests/golden`: expected only `+imageName` in every `Cluster`, new `platform-backup/` and `platform-backup-recovery/` dirs, `platform-recovery/` gaining ObjectStore/ScheduledBackup/plugin Application and Cluster `env`/`plugins`. Nothing else. Commit goldens separately.

### Task 7: Provider-neutral helpers and AWS wiring (snapshot path kept)

- [ ] Step 1 — `scripts/lib/provider.sh`: rename `civo_backup`→`backup_teardown`, `civo_archiving_status`→`backup_archiving_status`, `civo_archiving_since`→`backup_archiving_since`, `civo_backup_warn`→`backup_teardown_warn`; drop "on civo" from messages; replace `civo_recovery_handle` with:
```bash
# Absent on the first bring-up; empty means nothing to recover from.
backup_recovery_handle() {
  local value
  value="$(aws ssm get-parameter --region "$LAB_REGION" \
    --name "/$PROJECT_NAME/$1/postgres-backup/server_name" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ "$value" = "None" ] && value=""
  printf '%s' "$value"
}
```
- [ ] Step 2 — `scripts/argo-up.sh`:
  - `aws_resolve_inputs`: add `"/$PROJECT_NAME/persistent/backups/bucket_name"` to the batch; `BACKUP_BUCKET="$(ssm_output …)"`; update the "five" comment to six.
  - new `backup_resolve_generation() { RECOVER_SERVER_NAME="$(backup_recovery_handle "$BACKUP_SSM_LAYER")"; BACKUP_SERVER_NAME="lab-postgres-$(date -u +%Y%m%dT%H%M%SZ)"; }`, called at the end of both resolve functions (replaces civo lines 140-146).
  - lines 350-354: civo sets `RECOVERY_SNAPSHOT_HANDLE=""`; aws still calls `aws_resolve_snapshot`.
  - `aws_install_root_application`: add `--set postgres.backup.enabled=true`, `bucket`, `serverName`, `recoverServerName` (same four lines as civo 500-503).
  - rename `civo_publish_server_name`→`backup_publish_server_name` (path uses `$BACKUP_SSM_LAYER`), `civo_prune_backup_generations`→`backup_prune_generations`; call publish after `aws_wait_for_dns` too; remove "civo-only." from `POSTGRES_BACKUP_KEEP_GENERATIONS`.
- [ ] Step 3 — `scripts/argo-down.sh:150-154` becomes: `backup_teardown` on both providers, then `aws_cnpg_backup_and_prune` on aws. Plugin backup first: the cold snapshot fences the primary.
- [ ] Step 4 — `bash -n scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh`; `grep -rn 'civo_backup\|civo_archiving\|civo_recovery_handle\|civo_publish\|civo_prune' scripts Makefile .github` → no hits; `make gitops-check` PASS. Commit; push branch.

### Task 8: Dual cycle on AWS (live, ≈2 h)

- [ ] `TARGET_REVISION=civo-185-additive make up` (from the branch checkout). Log shows the snapshot recovery; `civo185_proof` count unchanged.
- [ ] `ContinuousArchiving=True`; `kubectl -n cnpg-system get backup` shows the `immediate` ScheduledBackup `completed`; `aws ssm get-parameter --name /vk-lab-platform/persistent/postgres-backup/server_name` equals the new generation.
- [ ] `aws s3 ls s3://vk-lab-platform-postgres-backups/<gen>/base/` shows a completed base backup (`backup.info` with `status=DONE`). **If it is missing, stop before Phase C**: Task 12 cycle 1 recovers from this generation and WAL alone cannot restore it.
- [ ] On the bring-up that recovers from the snapshot, the Cluster is admitted (no webhook rejection) and renders no `externalClusters` (D5).
- [ ] Insert rows `('dual-1')`, `('dual-2')`, then `('FINAL-DUAL')` right before teardown.
- [ ] `TARGET_REVISION=civo-185-additive make down`: log shows WAL switch, plugin Backup `completed`, then volumeSnapshot Backup `completed`; exit 0.
- [ ] `aws s3 ls s3://vk-lab-platform-postgres-backups/<gen>/wals/ --recursive | tail -3` and the newest EBS snapshot both exist. Record in §14. Merge PR `civo-185-additive` on approval.

---

## Phase C — Removal half (branch `civo-185-removal`)

### Task 9: Remove the snapshot surface from GitOps

- [ ] Step 1 — failing test: in `gitops-render-check.sh` add an aws check over every aws render dir: no `VolumeSnapshot*` kinds and no `Application__argocd__external-snapshotter*`; add `VolumeSnapshotContent`/`jsonPointers` absence check on the bootstrap root. `make gitops-check` → FAIL.
- [ ] Step 2 — delete `aws/postgres/recovered-snapshot.yaml`, `aws/ebs-csi/{snapshot-controller,volumesnapshotclass}.yaml`; `cluster.yaml`: remove the snapshot branch and `backup.volumeSnapshot` block, reword the storage comment (no snapshot restore size); remove `recoverySnapshotHandle` and `storage.snapshotClassName` from `gitops/values.yaml` and `gitops/bootstrap/values.yaml` (and their comments), the parameter at `root-application.yaml:28-29` and `ignoreDifferences` 87-94; `cert-manager/application.yaml` comment: replace the external-snapshotter example with a plain "controller-before-CRs" sentence.
- [ ] Step 3 — `gitops-render-check.sh`: delete the `platform-recovery` render (49-50); drop `external-snapshotter*` from forbidden-app lists and `VolumeSnapshot*` from forbidden-kind lists only if now redundant with the new aws check (keep them for civo/local — cheap).
- [ ] Step 4 — `make gitops-check` → structural PASS, golden FAIL. Commit. `update`, review: only removals (`platform-recovery/` dir, 3 snapshot objects, Cluster `backup` block, root `ignoreDifferences` + parameter). Commit goldens separately.

### Task 10: Remove the snapshot path from scripts

- [ ] `argo-up.sh`: delete `SNAPSHOT_TAG_FILTERS` (33-35), `aws_resolve_snapshot` and its dispatch (309-354), both `--set postgres.recoverySnapshotHandle` lines; reword the `POSTGRES_STORAGE_SIZE` comment.
- [ ] `argo-down.sh`: delete `BACKUP_TIMEOUT` and its comment (23-25), `SNAPSHOT_TAG_FILTERS` (27), `aws_cnpg_backup_and_prune` (80-148); dispatch becomes a plain `backup_teardown`; drop the three `volumesnapshot*` kinds from `TERMINATING_KINDS` (civo filter loop stays for karpenter kinds).
- [ ] Keep `scripts/lib/persistent-ebs-artifacts.sh` and snapshot deletion in `persistent-down.sh`; reword its header comment to "snapshots left from the retired snapshot mechanism".
- [ ] `bash -n`; `grep -rn 'VolumeSnapshot\|recoverySnapshotHandle\|snapshot-controller\|external-snapshotter' gitops scripts/argo-up.sh scripts/argo-down.sh tests/golden` → no hits (spec §8). Commit; push.

### Task 11: Documents

- [ ] New `docs/adr/0033-barman-cloud-plugin-backups-on-aws.md` (Status: Accepted. Supersedes ADR 0013). Context: snapshot = no PITR, fences primary, extra controllers. Decision: plugin on both targets; Pod Identity with `inheritFromIAMRole`; upstream multi-arch sidecar; pinned `imageName`; best-effort teardown under §4; generation pointer per SSM layer; additive→dual→removal cutover. Consequences: recovery time grows with WAL; cross-provider restore out (per-project buckets, CA-key blast radius, arm64/x86_64); old EBS snapshots cleaned only by `persistent-down`.
- [ ] ADR 0013: replace the note with "Superseded by ADR 0033 on <date>"; Status → `Superseded by ADR 0033`. ADR 0032 Status → "Accepted. Supersedes ADR 0031. Extended to AWS by ADR 0033."
- [ ] Constitution §4 L91 `(ADR 0032)` → `(ADR 0032, ADR 0033)`.
- [ ] `docs/architecture.md:544-553`: one persistence paragraph for both targets. `docs/aws-platform-design.md`: storage (drop VolumeSnapshotClass), teardown order (plugin `Backup` best-effort), persistent-down (bucket emptied). `tests/manual/007-postgres.md`: steps 3/7/8/12/13 rewritten to generation pointer, `ContinuousArchiving`, S3 prefixes. `specs/civo/decisions.md`: add ADR 0033 row. `Makefile:139-144` and `lifecycle-test.yml:42,187` wording.
- [ ] Spec 185 §14: D1–D4 deviations, gate evidence. Commit.

### Task 12: AWS cycles 1 and 2 on the plugin alone (live, ≈3 h)

- [ ] Cycle 1: `TARGET_REVISION=civo-185-removal make up`. Log shows no snapshot lookup; Cluster `bootstrap.recovery.source=lab-postgres-previous` with `serverName` = Task 8 generation. Every row incl. `FINAL-DUAL` present. Archiving into a new prefix. Record recovery time. Insert `('FINAL-C1')` immediately before `make down`.
- [ ] Cycle 2: same; `FINAL-C1` present; `aws s3 ls s3://vk-lab-platform-postgres-backups/<gen2>/wals/ | grep history` shows `.history`; three prefixes max-2 after prune (keep=2 plus current).
- [ ] Confirm `make down` log never waits on a snapshot; no new EBS snapshot created (`describe-snapshots` count unchanged).
- [ ] If recovery exceeds `ARGO_UP_WATCH_SECONDS` (2700) margin, record and raise it.

### Task 13: Civo regression cycle (live, ≈2 h)

On 2026-09-17 a CIVO-160 session ran `PROVIDER=civo make full-down`, which destroyed `vk-civo-lab-postgres-backups` and the Civo database. The Task 6 image guard therefore had nothing to read, and this cycle is a fresh start, not a data-continuity test. It still proves the template move and the image pin did not break Civo.

- [ ] Use a per-session `KUBECONFIG`. `PROVIDER=civo TARGET_REVISION=civo-185-removal make full-up`: `initdb` branch, the Cluster starts on the pinned image, the plugin Application uses the custom sidecar image, `ContinuousArchiving=True`, pointer at `/vk-civo-lab/persistent-civo/postgres-backup/server_name`.
- [ ] `terraform/live/persistent/backups` is not applied on Civo (`PERSISTENT_EXCLUDE=vpc backups`): no `vk-civo-lab` state under `persistent/backups/`.
- [ ] Write rows and a final row, `make down`, `make up`: plugin recovery from the first generation, every row present. `make down`.

### Task 14: Close

- [ ] `grep -rniE 'AKIA[0-9A-Z]{16}' --exclude-dir=.git .` → no hits; `grep -rn CI_TEARDOWN_ALLOW_DATA_LOSS --exclude-dir=.git . | grep -v 'specs/civo/115\|specs/civo/120\|docs/adr/0032\|docs/superpowers/plans'` → no hits.
- [ ] `make gitops-check`, `terraform fmt -recursive -check terraform/`, `bash -n` on changed scripts.
- [ ] Spec 185 DoD ticked, status DONE, `completed` date; `specs/civo/README.md` row DONE; `roadmap.md` M2 prose. Advisor review, then PR `civo-185-removal`; merge on approval.

## Rollback

- Before Task 9 merges: revert; snapshot recovery never left; Task 8's teardown snapshot is newest.
- After: revert Phase C; `aws_resolve_snapshot` finds the Task 8 snapshot. Rows written only after Task 8 live only in S3 and are lost on that path — state this before reverting. The bucket and pod-identity units can stay.

## Verification summary

- Offline per task: `make gitops-check`, `terraform fmt -recursive -check terraform/`, `terragrunt validate/plan`, `bash -n`.
- Live: Gates A/B (Tasks 4–5), dual cycle (Task 8), two plugin-only AWS cycles (Task 12), one Civo cycle (Task 13), each with row counts, final-row-before-teardown, prefixes and pointer values recorded in spec §14.

## Cost

S3 standard, a few GB with a 30-day backstop rule: under $1/month. Live work: ~6 AWS lifecycle hours (EKS + nodes ≈ $0.30/h) and ~2 Civo hours.
