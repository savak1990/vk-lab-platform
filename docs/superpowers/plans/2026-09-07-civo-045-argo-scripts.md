# CIVO-045 — Argo scripts on Civo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `PROVIDER=civo` branches to `scripts/argo-up.sh` and `scripts/argo-down.sh` so both scripts work against a Civo cluster, without changing a single byte of behavior on the AWS path.

**Architecture:** Extract the existing AWS-only logic in both scripts into named functions first (pure refactor, verified byte-identical), then add civo-branch functions beside them, selected by `if [ "$PROVIDER" = civo ]`. New provider-detection primitives (`civo_recovery_handle`, `civo_backup`) live in `scripts/lib/provider.sh` as permanent stubs that CIVO-120 will later replace the *bodies* of, not the call sites.

**Tech Stack:** bash (3.2-compatible, no associative arrays — stock macOS `/bin/bash`), `aws` CLI, `civo` CLI, `kubectl`, `helm`, `jq`, `shellcheck`.

**Spec:** `specs/civo/045-argo-scripts-civo-branches/spec.md`

**No test harness exists in this repo for shell scripts** (confirmed: no `shellcheck`/`bash -n` anywhere in CI or Makefile today). Do not invent one (no bats). The test cycle for every task in this plan is, in order:
1. `bash -n <script>` — syntax check.
2. `shellcheck <script>` — diffed against a baseline captured in Task 0, since these scripts have pre-existing warnings on the AWS-only code this plan must not touch or fix. The gate is **no new warnings**, not zero warnings.
3. For AWS-path tasks: a `bash -x` (redacted) command-line diff against the Task 0 baseline — proves zero behavior change.
4. For civo-path tasks: a real `PROVIDER=civo` run against the live civo cluster (Tasks 8/9) — there is no way to test these offline beyond `bash -n`/`shellcheck`, since they call live `civo`/`kubectl`/`aws` APIs.

## Global Constraints

- All new civo logic is guarded by `if [ "$PROVIDER" = civo ]`; the AWS branch of every conditional must be the pre-existing code, unmoved in substance (moved into a function is fine; edited is not).
- Never let a `set -x` trace or log line print `CIVO_TOKEN` or the ArgoCD admin bcrypt hash — spec §8 acceptance criterion.
- `civo_recovery_handle()` and `civo_backup()` in `scripts/lib/provider.sh` are the permanent seam for CIVO-120 — it replaces their bodies only, never their call sites in `argo-up.sh`/`argo-down.sh`.
- The civo LB firewall SSM parameter is `/${PROJECT_NAME}/cluster-civo/network/lb_firewall_id` (confirmed against `terraform/modules/civo-network/outputs.tf` — **not** `cluster_firewall_id`, and not the singular `firewall_id` spec.md's prose loosely uses).
- The civo DNS wait must be bounded and **non-fatal** on timeout — `external-dns` (spec 110) and the Envoy LB (spec 060) are not implemented yet as of this spec's dependencies (040, 050 only), so nothing may resolve in the M1 baseline this spec's own acceptance test targets. A fatal wait here would make acceptance criterion 1 (idempotent fast path) unreachable.
- Source `scripts/lib/provider.sh` in both scripts (neither sources it today) and use its `configure_kubeconfig`/`cluster_exists` instead of inline `aws eks update-kubeconfig`/`aws eks describe-cluster` calls — spec §4 requires this, and it is behavior-preserving (provider.sh's aws branch is byte-identical to the inline code it replaces — verified in Task 1/2).
- Spec.md's cited line numbers (§3) have drifted since it was written (`argo-down.sh` gained an "disarm automated sync" block after spec.md was authored). Every task below anchors edits to function names / comment landmarks, not line numbers, and Task 7 amends spec §3 to say so explicitly.
- Bootstrap chart plumbing (`gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`) is in scope even though spec §5 doesn't list it — without it, the `--set envoyGateway.reservedIp=...` etc. spec §4 requires would be silently dropped before reaching the root `Application`'s Helm parameters. Task 7 amends spec §5 to add these two files.

---

## Task 0: Capture AWS baselines (prerequisite — needs an AWS cluster up)

Nothing is edited in this task. It captures the "before" state Tasks 1/2 are diffed against.

**Files:** none. Raw `bash -x` traces contain the ArgoCD bcrypt hash and the real root domain (via `LAB_FQDN`/`dig` lines) — CLAUDE.md forbids committing either. Raw traces go to the scratchpad only; only a filtered, redacted command list is ever committed, to `specs/civo/045-argo-scripts-civo-branches/evidence/` (create this directory in Step 4).

- [ ] **Step 1: Confirm an AWS cluster is currently up**

```bash
make status
```

If it reports no cluster, **stop and ask the user** before running `make up` — that's real AWS spend, not something to do unprompted mid-plan.

- [ ] **Step 2: Capture a raw `bash -x` trace of the AWS fast path, to the scratchpad — never the repo**

The fast path is the branch that exits at the "already Synced/Healthy" check (`scripts/argo-up.sh`, the `EXISTING_STATUS` check). Run:

```bash
bash -x scripts/argo-up.sh 2> /tmp/aws-fastpath-baseline.raw
```

- [ ] **Step 3: Extract and redact only the commands actually run, then review before committing anything**

```bash
grep -E '^\+ (helm|aws|kubectl|dig) ' /tmp/aws-fastpath-baseline.raw | sed -E \
    -e 's/(--set configs\.secret\.argocdServerAdminPassword=)[^ ]+/\1<redacted>/' \
    -e 's/(--names )\/[^ ]+/\1<redacted>/' \
    -e "s#(dig \+short )'?argo\.[^ ']+#\1<redacted-fqdn>#" \
  > /tmp/aws-fastpath-baseline.filtered
cat /tmp/aws-fastpath-baseline.filtered   # eyeball it: confirm no bcrypt hash, no root domain, no token anywhere
```

Only once this file is confirmed clean, copy it into the repo:

```bash
mkdir -p specs/civo/045-argo-scripts-civo-branches/evidence
cp /tmp/aws-fastpath-baseline.filtered specs/civo/045-argo-scripts-civo-branches/evidence/aws-fastpath-baseline.txt
```

- [ ] **Step 4: Capture a shellcheck baseline**

```bash
shellcheck scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh \
  > specs/civo/045-argo-scripts-civo-branches/evidence/shellcheck-baseline.txt 2>&1 || true
```

(`|| true`: shellcheck exits non-zero when it finds anything; we want the file even if it's non-empty. This file has no secrets in it — safe to commit as-is.)

- [ ] **Step 5: Commit the evidence directory**

```bash
git add specs/civo/045-argo-scripts-civo-branches/evidence/
git commit -m "civo-045: capture AWS argo-up fast-path and shellcheck baselines"
```

---

## Task 1: Extract AWS-only blocks in `argo-up.sh` into functions (no behavior change)

**Files:**
- Modify: `scripts/argo-up.sh`

**Interfaces:**
- Produces: `aws_resolve_inputs()` (sets `CLUSTER_NAME`, `ACM_CERTIFICATE_ARN`, `VPC_ID`, `NODE_SUBNET_ID`, `LAB_FQDN`; configures kubeconfig), `aws_resolve_snapshot()` (sets `RECOVERY_SNAPSHOT_HANDLE`, prunes old snapshots), `install_argocd()` (takes no args, reads `$PROVIDER` internally for the anti-affinity flag), `aws_install_root_application()` (reads `$RECOVERY_SNAPSHOT_HANDLE`), `aws_wait_for_dns()` (renamed from the existing `wait_for_dns`, unchanged body).

- [ ] **Step 1: Add `source scripts/lib/provider.sh` and wrap the input-resolution block into `aws_resolve_inputs()`**

Replace lines 9–11 (`REPO_ROOT=...` through `source "$REPO_ROOT/scripts/lib/region.sh"`) with:

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"
```

(`provider.sh` exports `PROJECT_NAME`/`CLUSTER_NAME` defaults — drop the script's own `PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"` line, since provider.sh's aws-branch default is identical: `vk-lab-platform`.)

`eks_output` and the `ssm_output` helper function definition stay at top level (used again later — see below). But the SSM **batch fetch itself** (the `SSM_NAMES=(...)` array and the `while IFS=$'\t' read ...` loop that populates `SSM_BATCH_NAMES`/`SSM_BATCH_VALUES`, current lines 41–54) is itself part of the AWS-only block spec §3 names — it fetches `bootstrap/acm/certificate_arn`, `persistent/vpc/vpc_id`, and `cluster/eks/node_subnet_id`, none of which exist on civo. Move it, and the `ADMIN_PASSWORD_BCRYPT_HASH` lookup (current line 199, moved up — a pure local reorder, no new external call), inside the function:

```bash
aws_resolve_inputs() {
  local ssm_names=(
    "/$PROJECT_NAME/bootstrap/acm/certificate_arn"
    "/$PROJECT_NAME/persistent/vpc/vpc_id"
    "/$PROJECT_NAME/cluster/eks/node_subnet_id"
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
  )
  SSM_BATCH_NAMES=()
  SSM_BATCH_VALUES=()
  while IFS=$'\t' read -r name value; do
    SSM_BATCH_NAMES+=("$name")
    SSM_BATCH_VALUES+=("$value")
  done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
    --names "${ssm_names[@]}" --query 'Parameters[].[Name,Value]' --output text)

  CLUSTER_NAME="$(eks_output cluster_name)"
  ACM_CERTIFICATE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/acm/certificate_arn")"
  VPC_ID="$(ssm_output "/$PROJECT_NAME/persistent/vpc/vpc_id")"
  NODE_SUBNET_ID="$(ssm_output "/$PROJECT_NAME/cluster/eks/node_subnet_id")"
  # fqdn ("lab.<root-domain>") is sensitive - never echo it, including via a
  # full hostname built from it (label DNS output by short name instead).
  LAB_FQDN="$(ssm_output "/$PROJECT_NAME/bootstrap/route53/fqdn")"
  ADMIN_PASSWORD_BCRYPT_HASH="$(ssm_output "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt")"
  configure_kubeconfig
}
```

`SSM_NAMES` (the old top-level array, now folded into the local `ssm_names` above) and the old top-level `while` loop are deleted from top level entirely — `ssm_output` (which stays a top-level function, since `civo_resolve_inputs` in Task 4 does not use it) now only ever gets called from inside `aws_resolve_inputs`.

- [ ] **Step 2: Call `aws_resolve_inputs` in place of the old inline code, under a provider branch**

Where the old inline block used to run (right after the SSM batch/helper definitions), add:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_resolve_inputs   # added in Task 4
else
  aws_resolve_inputs
fi
```

- [ ] **Step 3: Wrap the snapshot discovery+pruning block into `aws_resolve_snapshot()`**

Wrap the existing block (current lines 160–197, from the "Discovers the latest Postgres EBS snapshot" comment through the pruning loop) verbatim into:

```bash
aws_resolve_snapshot() {
  if ! SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$LAB_REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
    echo "ARGO-UP: failed to query AWS for existing Postgres snapshots - aborting rather than risking a false 'fresh start'." >&2
    exit 1
  fi
  RECOVERY_SNAPSHOT_HANDLE="$(echo "$SNAPSHOTS_JSON" | jq -r '.[-1].SnapshotId // ""')"
  if [ -n "$RECOVERY_SNAPSHOT_HANDLE" ]; then
    echo "ARGO-UP: found latest Postgres snapshot $RECOVERY_SNAPSHOT_HANDLE - will recover from it."
  else
    echo "ARGO-UP: no existing Postgres snapshot found - will bootstrap fresh (initdb)."
  fi

  if ! ALL_SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$LAB_REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" \
    --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
    echo "ARGO-UP: failed to query AWS for Postgres snapshots to prune - aborting." >&2
    exit 1
  fi
  OLD_SNAPSHOTS="$(echo "$ALL_SNAPSHOTS_JSON" | jq -r '.[:-2][].SnapshotId')"
  if [ -n "$OLD_SNAPSHOTS" ]; then
    for snapshot_id in $OLD_SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$LAB_REGION" --snapshot-id "$snapshot_id"
      echo "ARGO-UP: pruned old snapshot $snapshot_id"
    done
  fi
}
```

Call it where the block used to run:

```bash
if [ "$PROVIDER" = civo ]; then
  RECOVERY_SNAPSHOT_HANDLE="$(civo_recovery_handle)"
else
  aws_resolve_snapshot
fi
```

- [ ] **Step 4: Extract the Argo CD helm install into `install_argocd()`, parameterized on `$PROVIDER` for the anti-affinity flags**

Replace the existing `helm upgrade --install argocd ...` block (current lines 201–224) with:

```bash
install_argocd() {
  local antiaffinity_args=()
  if [ "$PROVIDER" != civo ]; then
    antiaffinity_args=(
      --set global.affinity.nodeAffinity.type=hard
      --set-json 'global.affinity.nodeAffinity.matchExpressions=[{"key":"karpenter.sh/capacity-type","operator":"NotIn","values":["spot"]}]'
    )
  fi
  helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    -f "$REPO_ROOT/gitops/argocd/values.yaml" \
    --set server.service.type=ClusterIP \
    --set configs.params."server\.insecure"=true \
    --set configs.secret.argocdServerAdminPassword="$ADMIN_PASSWORD_BCRYPT_HASH" \
    --set configs.secret.argocdServerAdminPasswordMtime="2026-08-20T00:00:00Z" \
    --set controller.metrics.enabled=true \
    --set server.metrics.enabled=true \
    --set repoServer.metrics.enabled=true \
    --set applicationSet.metrics.enabled=true \
    --set notifications.metrics.enabled=true \
    --set-json 'controller.resources={"requests":{"cpu":"20m","memory":"512Mi"},"limits":{"memory":"768Mi"}}' \
    --set-json 'repoServer.resources={"requests":{"cpu":"10m","memory":"192Mi"},"limits":{"memory":"320Mi"}}' \
    --set-json 'server.resources={"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"128Mi"}}' \
    --set-json 'applicationSet.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'dex.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'notifications.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'redis.resources={"requests":{"cpu":"5m","memory":"32Mi"},"limits":{"memory":"64Mi"}}' \
    ${antiaffinity_args[@]:+"${antiaffinity_args[@]}"} \
    --wait
}
```

`"${antiaffinity_args[@]}"` unquoted-empty-array form, **not** the bare `"${antiaffinity_args[@]}"` — on civo the array is empty, and under `set -u` bash <4.4 (this repo targets bash 3.2 compatibility, per the existing `configure_kubeconfig` in `provider.sh` using the same `${kcfg[@]:+"${kcfg[@]}"}` guard) raises "unbound variable" expanding an empty array directly. This only breaks on the civo path — the AWS path's array is always non-empty, so Task 1's own `set -x` diff won't catch it; it will only surface in Task 8's live civo run if missed here.

`ADMIN_PASSWORD_BCRYPT_HASH` is already set by `aws_resolve_inputs()` (Step 1 above) for aws, and by `civo_resolve_inputs()` (Task 4) for civo. Call `install_argocd` unconditionally where the old inline block ran — the function itself branches internally on `$PROVIDER`.

- [ ] **Step 5: Extract the root Application install into `aws_install_root_application()`**

Replace the existing `helm upgrade --install root-application ...` block (current lines 235–251) with:

```bash
aws_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=aws \
    --set project="$PROJECT_NAME" \
    --set vpcId="$VPC_ID" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.recoverySnapshotHandle="$RECOVERY_SNAPSHOT_HANDLE" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set karpenter.spot.cpuLimit="$SPOT_KARPENTER_CPU_LIMIT" \
    --set karpenter.onDemand.cpuLimit="$ON_DEMAND_KARPENTER_CPU_LIMIT" \
    --set-json karpenter.spot.instanceTypes="$SPOT_KARPENTER_INSTANCE_TYPES_JSON" \
    --set-json karpenter.onDemand.instanceTypes="$ON_DEMAND_KARPENTER_INSTANCE_TYPES_JSON" \
    --set envoyGateway.acmCertificateArn="$ACM_CERTIFICATE_ARN" \
    --set envoyGateway.nlbSubnetIds="$NODE_SUBNET_ID" \
    --set envoyGateway.fqdn="$LAB_FQDN"
}
```

Call it where the block ran:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_install_root_application   # added in Task 4
else
  aws_install_root_application
fi
```

- [ ] **Step 6: Rename `wait_for_dns` to `aws_wait_for_dns`, body unchanged**

Rename the function (current lines 115–140) and its two call sites (current lines 155, 329) to `aws_wait_for_dns`. No other change. At each call site, branch:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_wait_for_dns
else
  aws_wait_for_dns
fi
```

(`civo_wait_for_dns`, added in Task 4, is deliberately non-fatal on timeout — it returns 0 either way. That means the unconditional `echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."` line that currently follows both call sites is wrong on a civo timeout: it would claim DNS resolved when it didn't. Have `civo_wait_for_dns` itself print the final "platform ready" line on success and a distinct "platform ready (DNS not yet resolved, non-fatal)" line on timeout, and skip the shared trailing echo on the civo branch — i.e. wrap the shared echo in `if [ "$PROVIDER" != civo ]; then ... fi` at both of the two call sites this step touches.)

- [ ] **Step 7: `bash -n` check**

```bash
bash -n scripts/argo-up.sh
```

Expected: no output, exit 0.

- [ ] **Step 8: shellcheck diff against baseline**

```bash
shellcheck scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh > /tmp/sc-after-task1.txt 2>&1 || true
diff specs/civo/045-argo-scripts-civo-branches/evidence/shellcheck-baseline.txt /tmp/sc-after-task1.txt
```

Expected: no new warning lines (removed warnings, e.g. from lines that moved, are fine; anything genuinely new about the AWS path is not — fix it before proceeding).

- [ ] **Step 9: `set -x` diff against the Task 0 baseline (AWS fast path only — civo branches don't exist to call yet)**

Raw trace stays in the scratchpad, never the repo — same reasoning as Task 0.

```bash
bash -x scripts/argo-up.sh 2> /tmp/aws-fastpath-after-task1.raw
grep -E '^\+ (helm|aws|kubectl|dig) ' /tmp/aws-fastpath-after-task1.raw | sed -E \
    -e 's/(--set configs\.secret\.argocdServerAdminPassword=)[^ ]+/\1<redacted>/' \
    -e 's/(--names )\/[^ ]+/\1<redacted>/' \
    -e "s#(dig \+short )'?argo\.[^ ']+#\1<redacted-fqdn>#" \
  > /tmp/aws-fastpath-after-task1.filtered
diff specs/civo/045-argo-scripts-civo-branches/evidence/aws-fastpath-baseline.txt /tmp/aws-fastpath-after-task1.filtered
```

Expected: no diff in the sequence of `helm`/`aws`/`kubectl`/`dig` commands actually executed. This filtered file is not committed — it's a one-off check; Task 9 captures the final post-implementation evidence that does get committed.

- [ ] **Step 10: Commit**

```bash
git add scripts/argo-up.sh
git commit -m "civo-045: extract AWS-only blocks in argo-up.sh into functions (no behavior change)"
```

---

## Task 2: Extract AWS-only blocks in `argo-down.sh` into functions (no behavior change)

**Files:**
- Modify: `scripts/argo-down.sh`

**Interfaces:**
- Consumes: `configure_kubeconfig()`, `cluster_exists()` from `scripts/lib/provider.sh` (Task 1 already sources it in argo-up.sh; this task sources it in argo-down.sh).
- Produces: `aws_cnpg_backup_and_prune()` (the existing volumeSnapshot backup + EBS prune block, unchanged body).

- [ ] **Step 1: Source `provider.sh`; replace the existence-proof + kubeconfig block with `cluster_exists`/`configure_kubeconfig`**

Replace the existing block (current lines 18–37: `TIMEOUT=...` through the `kubectl config set-context` line) with:

```bash
TIMEOUT="${ARGO_DOWN_TIMEOUT:-900s}"
POLL_INTERVAL="${ARGO_DOWN_POLL_INTERVAL:-5}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"
BACKUP_TIMEOUT="${ARGO_DOWN_BACKUP_TIMEOUT:-120s}"
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

# Absence is checked against the provider's own API (cluster_exists), not
# kubectl - a describe-cluster/kubernetes-show 404 is proof the cluster is
# gone (safe to skip), whereas a kubectl failure only proves this shell has
# no working kubeconfig, never proof of absence.
if ! cluster_exists; then
  echo "ARGO-DOWN: cluster $CLUSTER_NAME does not exist - nothing to cascade, skipping."
  exit 0
fi

configure_kubeconfig
```

(`provider.sh`'s aws-branch default for `CLUSTER_NAME` is `${PROJECT_NAME}-eks`, identical to the script's old hardcoded `CLUSTER_NAME="${PROJECT_NAME}-eks"` — dropping that line is behavior-preserving. `PROJECT_NAME` default is likewise identical: `vk-lab-platform`. Note `REPO_ROOT` moves up from its old position further down the file — the old `REPO_ROOT="$(cd ... )"` line lower in the file, current line 193, becomes redundant; delete it there.)

- [ ] **Step 2: Move the reachability check (current lines 39–45) to right after `configure_kubeconfig`, unchanged**

```bash
if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "ARGO-DOWN: ERROR - cluster $CLUSTER_NAME exists but is unreachable via kubectl (cluster-info failed)." >&2
  echo "ARGO-DOWN: refusing to proceed: without API access there is no way to ask Karpenter/aws-load-balancer-" >&2
  echo "ARGO-DOWN: controller to drain nodes and delete load balancers before the control plane is destroyed -" >&2
  echo "ARGO-DOWN: proceeding blind orphans them. Investigate cluster/API-server health before retrying." >&2
  exit 1
fi
```

- [ ] **Step 3: Wrap the CNPG backup+prune block into `aws_cnpg_backup_and_prune()`**

Wrap the existing block verbatim (current lines 72–138, from `if kubectl get cluster lab-postgres ...` through the closing `fi` of the else branch) into a function of that name, body byte-identical. Call it where the block used to run, guarded:

```bash
if [ "$PROVIDER" != civo ]; then
  aws_cnpg_backup_and_prune
fi
```

- [ ] **Step 4: `bash -n` check**

```bash
bash -n scripts/argo-down.sh
```

- [ ] **Step 5: shellcheck diff against baseline** (same method as Task 1 Step 8)

- [ ] **Step 6: Commit**

```bash
git add scripts/argo-down.sh
git commit -m "civo-045: extract AWS-only blocks in argo-down.sh into functions (no behavior change)"
```

---

## Task 3: Add `civo_recovery_handle()` and `civo_backup()` stubs to `provider.sh`

**Files:**
- Modify: `scripts/lib/provider.sh`

**Interfaces:**
- Produces: `civo_recovery_handle()` (prints a recovery handle string, or empty; also usable as `RECOVERY_SNAPSHOT_HANDLE="$(civo_recovery_handle)"`), `civo_backup()` (exits 1 with a clear message if a CNPG `Cluster` exists on civo; otherwise logs and returns 0).

- [ ] **Step 1: Append both functions to the end of `provider.sh`**

```bash

# CIVO-120 will replace this body with a real recovery handle for CNPG's
# plugin-based restore path. Until then there is no restore mechanism on
# civo, so every argo-up bootstraps fresh - the call site in argo-up.sh
# stays the same either way.
civo_recovery_handle() {
  echo "ARGO-UP: no recovery configured for civo yet (CIVO-120) - bootstrapping fresh." >&2
  printf ''
}

# CIVO-120 will replace this body with a real on-demand CNPG plugin backup
# to object storage. Until then, refuse to tear down a cluster that still
# has Postgres data rather than silently losing it. The CNPG CRD may not be
# installed at all on a bare civo baseline - that is "no cluster", not an
# error, so a missing CRD must not be treated the same as a failed check.
civo_backup() {
  if kubectl get clusters.postgresql.cnpg.io -A >/dev/null 2>&1; then
    if [ -n "$(kubectl get clusters.postgresql.cnpg.io -A -o name 2>/dev/null)" ]; then
      echo "ARGO-DOWN: a CNPG Cluster exists on civo but CIVO-120's backup path isn't implemented yet - refusing to tear down and risk losing Postgres data." >&2
      exit 1
    fi
  fi
  echo "ARGO-DOWN: no CNPG Cluster found on civo - nothing to back up."
}
```

- [ ] **Step 2: `bash -n` and shellcheck**

```bash
bash -n scripts/lib/provider.sh
shellcheck scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh > /tmp/sc-after-task3.txt 2>&1 || true
diff specs/civo/045-argo-scripts-civo-branches/evidence/shellcheck-baseline.txt /tmp/sc-after-task3.txt
```

- [ ] **Step 3: Manual smoke test against a live civo cluster, if one is up**

```bash
PROVIDER=civo bash -c 'source scripts/lib/provider.sh; civo_backup; echo "exit=$?"'
```

Expected on a bare civo-050 baseline (no CNPG installed yet): `ARGO-DOWN: no CNPG Cluster found on civo - nothing to back up.` then `exit=0`. If no civo cluster is up yet, defer this check to Task 8.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/provider.sh
git commit -m "civo-045: add civo_recovery_handle and civo_backup stubs, fail-closed until CIVO-120"
```

---

## Task 4: `argo-up.sh` civo branches

**Files:**
- Modify: `scripts/argo-up.sh`

**Interfaces:**
- Consumes: `civo_token()`, `civo_cli()`, `configure_kubeconfig()`, `civo_recovery_handle()` from `provider.sh`; `PROJECT_NAME`, `CLUSTER_NAME`, `CIVO_REGION` env vars provider.sh exports/expects.
- Produces: `civo_resolve_inputs()`, `civo_install_root_application()`, `civo_wait_for_dns()`.

- [ ] **Step 1: Verify the civo SSM parameter paths actually exist before writing the batch fetch**

```bash
aws ssm get-parameters-by-path --path "/vk-civo-lab/" --recursive --query 'Parameters[].Name' --output text
```

Confirm the four paths used in Step 2 below actually exist: `/vk-civo-lab/bootstrap/route53/fqdn` (civo's bootstrap stack runs with `BOOTSTRAP_EXCLUDE=acm` only — route53 still runs, same relative path as AWS), `/vk-civo-lab/persistent/argocd/admin_password_bcrypt` (confirmed in research: shared `terraform/modules/persistent-secrets` module, same relative path as AWS under the civo project name), `/vk-civo-lab/persistent-civo/reserved-ip/address`, and `/vk-civo-lab/cluster-civo/network/lb_firewall_id` (both confirmed in research). If any of the four is missing from the `get-parameters-by-path` output, fix the literal in Step 2 to match what's actually there before proceeding — don't guess a second time.

- [ ] **Step 2: Write `civo_resolve_inputs()`**

```bash
civo_resolve_inputs() {
  civo_token
  local civo_ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-civo/reserved-ip/address"
    "/$PROJECT_NAME/cluster-civo/network/lb_firewall_id"
  )
  local civo_ssm_batch_names=() civo_ssm_batch_values=()
  while IFS=$'\t' read -r name value; do
    civo_ssm_batch_names+=("$name")
    civo_ssm_batch_values+=("$value")
  done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
    --names "${civo_ssm_names[@]}" --query 'Parameters[].[Name,Value]' --output text)

  local i
  for i in "${!civo_ssm_names[@]}"; do
    local found=""
    local j
    for j in "${!civo_ssm_batch_names[@]}"; do
      [ "${civo_ssm_batch_names[$j]}" = "${civo_ssm_names[$i]}" ] && { found="${civo_ssm_batch_values[$j]}"; break; }
    done
    if [ -z "$found" ]; then
      echo "ARGO-UP: missing SSM parameter ${civo_ssm_names[$i]} - has its owning terragrunt unit been applied?" >&2
      exit 1
    fi
    case "${civo_ssm_names[$i]}" in
      */fqdn) LAB_FQDN="$found" ;;
      */admin_password_bcrypt) ADMIN_PASSWORD_BCRYPT_HASH="$found" ;;
      */reserved-ip/address) RESERVED_IP="$found" ;;
      */lb_firewall_id) FIREWALL_ID="$found" ;;
    esac
  done

  configure_kubeconfig
}
```

If Step 1 found any of the four paths missing or under a different prefix, fix the corresponding literal in `civo_ssm_names` before continuing.

- [ ] **Step 3: Wire `civo_resolve_inputs` into the provider branch added in Task 1 Step 2** (already has the `if`/`else` shell — just confirm the civo arm calls this function).

- [ ] **Step 4: Write `civo_install_root_application()`**

```bash
civo_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=civo \
    --set project="$PROJECT_NAME" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.recoverySnapshotHandle="$RECOVERY_SNAPSHOT_HANDLE" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set envoyGateway.fqdn="$LAB_FQDN" \
    --set envoyGateway.reservedIp="$RESERVED_IP" \
    --set envoyGateway.firewallId="$FIREWALL_ID" \
    --set externalDns.txtOwnerId="$PROJECT_NAME"
}
```

(No `karpenter.*` or `vpcId` flags — civo has neither Karpenter nor a VPC concept wired yet at this spec's dependency level; spec §4 explicitly omits them from the civo `--set` list.)

- [ ] **Step 5: Write `civo_wait_for_dns()` — bounded, non-fatal**

Neither `external-dns` (spec 110) nor the Civo-specific Envoy LB wiring (spec 060) exist yet in this spec's dependency chain (040, 050 only) — nothing may resolve. This must never block the fast path from completing (acceptance criterion 1).

```bash
civo_wait_for_dns() {
  local watch_seconds="${CIVO_ARGO_UP_DNS_WATCH_SECONDS:-60}"
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 svc_ip="" dig_ip=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    svc_ip="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -z "$svc_ip" ] && svc_ip="$RESERVED_IP"
    dig_ip="$(dig +short "argo.$LAB_FQDN" 2>/dev/null | tail -n1 || true)"
    if [ -n "$dig_ip" ] && [ -n "$svc_ip" ] && [ "$dig_ip" = "$svc_ip" ]; then
      echo "ARGO-UP: DNS resolved (argo.<fqdn> -> matches Envoy Service/reserved IP)."
      echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
      return 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: DNS not resolved for argo.<fqdn> after ${watch_seconds}s - non-fatal on civo (external-dns/spec 110 and the Envoy LB/spec 060 aren't implemented in this baseline yet)." >&2
  echo "ARGO-UP: root Synced/Healthy - platform ready (DNS not yet resolved, non-fatal on civo)."
  return 0
}
```

This function now owns its own terminal status line — at both call sites this step touches, the shared trailing `echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."` must be wrapped `if [ "$PROVIDER" != civo ]; then ... fi` (civo's version of that line comes from inside the function above instead).

- [ ] **Step 6: Wire `civo_wait_for_dns` into the two call sites added in Task 1 Step 6.**

- [ ] **Step 7: `bash -n` and shellcheck**

```bash
bash -n scripts/argo-up.sh
shellcheck scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh > /tmp/sc-after-task4.txt 2>&1 || true
diff specs/civo/045-argo-scripts-civo-branches/evidence/shellcheck-baseline.txt /tmp/sc-after-task4.txt
```

- [ ] **Step 8: Commit**

```bash
git add scripts/argo-up.sh
git commit -m "civo-045: add civo branches to argo-up.sh"
```

(Live verification of this task happens in Task 8, alongside the bootstrap chart plumbing from Task 5 — `civo_install_root_application`'s `--set envoyGateway.reservedIp=...` etc. do nothing useful until Task 5 lands.)

---

## Task 5: Bootstrap chart plumbing for the new civo `--set` values

**Files:**
- Modify: `gitops/bootstrap/values.yaml`
- Modify: `gitops/bootstrap/templates/root-application.yaml`

**Interfaces:**
- Consumes: the `--set envoyGateway.reservedIp=...`, `--set envoyGateway.firewallId=...`, `--set externalDns.txtOwnerId=...` flags Task 4 added to `civo_install_root_application()`.
- Produces: those three values forwarded into the root `Application`'s `spec.source.helm.parameters`, where the main `gitops/` chart can read them once spec 060/110 add templates that consume them (this task adds the pass-through, not the consumers — unused Helm parameters are harmless).

**Why this file pair, not spec §5's original three scripts:** `gitops/bootstrap`'s `values.yaml` is what `helm upgrade --install root-application $REPO_ROOT/gitops/bootstrap --set envoyGateway.reservedIp=...` actually sets — but `root-application.yaml`'s `spec.source.helm.parameters` list is a second, separate hop that forwards *named* values into the real root `Application`'s Helm parameters (which target the main `gitops/` chart). A value not listed there never reaches the main chart, no matter what `--set` on the `helm upgrade --install root-application` command says.

- [ ] **Step 1: Add the three keys to `gitops/bootstrap/values.yaml`**

```yaml
envoyGateway:
  acmCertificateArn: ""
  nlbSubnetIds: ""
  fqdn: ""
  reservedIp: ""
  firewallId: ""

externalDns:
  txtOwnerId: ""
```

(Append `reservedIp`/`firewallId` under the existing `envoyGateway:` block; add the new top-level `externalDns:` block after it.)

- [ ] **Step 2: Add matching parameter entries to `gitops/bootstrap/templates/root-application.yaml`**

Insert after the existing `envoyGateway.fqdn` parameter entry (inside `spec.source.helm.parameters`):

```yaml
        - name: envoyGateway.reservedIp
          value: {{ .Values.envoyGateway.reservedIp | quote }}
        - name: envoyGateway.firewallId
          value: {{ .Values.envoyGateway.firewallId | quote }}
        - name: externalDns.txtOwnerId
          value: {{ .Values.externalDns.txtOwnerId | quote }}
```

- [ ] **Step 3: `helm template` the bootstrap chart to confirm it renders**

```bash
helm template root-application gitops/bootstrap --set target=civo \
  --set envoyGateway.reservedIp=1.2.3.4 --set envoyGateway.firewallId=fw-123 \
  --set externalDns.txtOwnerId=vk-civo-lab | grep -A2 'name: envoyGateway.reservedIp'
```

Expected: the parameter block appears with `value: "1.2.3.4"`.

- [ ] **Step 4: Confirm the bootstrap chart's own render only gains the three new parameter entries — nothing else changes**

`tests/golden/gitops-aws` renders the main `gitops/` chart, not `gitops/bootstrap` — irrelevant to this task, skip it. Instead diff the bootstrap chart's own render against itself before/after this change:

```bash
helm template root-application gitops/bootstrap --set target=aws > /tmp/bootstrap-after.yaml
git stash
helm template root-application gitops/bootstrap --set target=aws > /tmp/bootstrap-before.yaml
git stash pop
diff /tmp/bootstrap-before.yaml /tmp/bootstrap-after.yaml
```

Expected: exactly three new `parameters` entries (`envoyGateway.reservedIp`, `envoyGateway.firewallId`, `externalDns.txtOwnerId`), each with `value: ""` on the `target=aws` render (the empty defaults from Step 1) — not byte-identical, but additive-only with no change to any existing entry.

- [ ] **Step 5: Commit**

```bash
git add gitops/bootstrap/values.yaml gitops/bootstrap/templates/root-application.yaml
git commit -m "civo-045: plumb envoyGateway.reservedIp/firewallId and externalDns.txtOwnerId through the bootstrap chart"
```

---

## Task 6: `argo-down.sh` civo branches

**Files:**
- Modify: `scripts/argo-down.sh`

**Interfaces:**
- Consumes: `civo_backup()` from `provider.sh` (Task 3).

- [ ] **Step 1: Call `civo_backup` before the "disarm automated sync" block, not after**

The disarm loop patches every Application's `syncPolicy.automated` to null and aborts in-flight syncs — a mutation with real consequences (GitOps stays disarmed until the next `argo-up`). Since `civo_backup()` may `exit 1` (CIVO-120 not landed yet, refusing to risk data loss), running it *before* the disarm loop means a refusal leaves the cluster's GitOps fully armed, not half-disarmed.

Insert immediately after the reachability check (Task 2 Step 2), before the "Disarming automated sync" comment block:

```bash
if [ "$PROVIDER" = civo ]; then
  civo_backup
fi
```

Also fix the disarm block's own re-arm message (the `"ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'make argo-up'..."` line, run right after this for both providers): on civo, re-arming needs `PROVIDER=civo make argo-up`, not bare `make argo-up`. Guard the message itself, so the AWS wording stays byte-for-byte identical (this is a shared block that runs for both providers — an unconditional substitution would change the AWS message too, which the "AWS output stays byte-identical" constraint doesn't allow):

```bash
if [ "$DISARMED" -gt 0 ]; then
  if [ "$PROVIDER" = civo ]; then
    echo "ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'PROVIDER=civo make argo-up' if you stop here."
  else
    echo "ARGO-DOWN: automated sync disarmed on $DISARMED Application(s) - re-arm with 'make argo-up' if you stop here."
  fi
fi
```

- [ ] **Step 2: Skip the AWS CNPG backup+prune call on civo** (already done structurally in Task 2 Step 3 — confirm the guard reads `if [ "$PROVIDER" != civo ]; then aws_cnpg_backup_and_prune; fi`, i.e. civo does no EBS-snapshot pruning at all — there is no EBS on civo, and Civo's dangling-volume sweep already lives in `cluster-down.sh`, not here).

- [ ] **Step 3: Confirm the Route 53 wait and the LB wait need no civo branch**

Read both blocks (the "ExternalDNS-owned Route 53 records" wait and the "Envoy-managed NLB Service" wait) and confirm neither calls any AWS-only command that would fail or behave wrong on a civo cluster — both use only `kubectl`/`aws route53`/`dig`, none of which are EKS-specific, and per spec §4 both are explicitly "unchanged" on civo (AWS credentials/Route 53 zone are shared across providers; the LB-Service-drain logic is provider-agnostic `kubectl` against whichever CCM populated the Service). **Do not add a civo branch here** — this step is a verification, not an edit.

- [ ] **Step 4: Filter `TERMINATING_KINDS` to kinds actually registered on the cluster, for civo**

Insert right after the `TERMINATING_KINDS="..."` assignment:

```bash
if [ "$PROVIDER" = civo ]; then
  filtered_kinds=""
  for kind in $TERMINATING_KINDS; do
    kubectl get "$kind" -A >/dev/null 2>&1 && filtered_kinds="$filtered_kinds $kind"
  done
  TERMINATING_KINDS="$filtered_kinds"
fi
```

`kubectl get <kind> -A` exits non-zero for an unregistered resource type and zero for a registered type (even with zero matching objects) — that's the discriminator needed. **Do not** filter by comparing against `kubectl api-resources -o name` output with `grep -qxF`: `api-resources -o name` prints plural forms (`applications.argoproj.io`, `clusters.postgresql.cnpg.io`), while `TERMINATING_KINDS` holds singular forms (`application.argoproj.io`, `cluster.postgresql.cnpg.io`) — an exact-string match between the two never succeeds, silently filtering the list down to empty and making `report_remaining()` permanently report nothing stuck on civo.

(On the M1 civo baseline, Karpenter isn't installed — `nodepool.karpenter.sh`, `ec2nodeclass.karpenter.k8s.aws`, `nodeclaim.karpenter.sh` would otherwise be checked against an unregistered API group every poll interval. `report_remaining()`'s existing `2>/dev/null || true` already tolerates that safely, so this is a noise-reduction/spec-compliance change, not a correctness fix — verify with `kubectl api-resources` output on the live cluster in Task 8 before assuming which kinds are actually absent.)

- [ ] **Step 5: `bash -n` and shellcheck**

```bash
bash -n scripts/argo-down.sh
shellcheck scripts/argo-up.sh scripts/argo-down.sh scripts/lib/provider.sh > /tmp/sc-after-task6.txt 2>&1 || true
diff specs/civo/045-argo-scripts-civo-branches/evidence/shellcheck-baseline.txt /tmp/sc-after-task6.txt
```

- [ ] **Step 6: Commit**

```bash
git add scripts/argo-down.sh
git commit -m "civo-045: add civo branches to argo-down.sh"
```

---

## Task 7: Amend spec.md

**Files:**
- Modify: `specs/civo/045-argo-scripts-civo-branches/spec.md`

- [ ] **Step 1: Add a dated correction to §3** noting that the cited line numbers have drifted (cite the "disarm automated sync" block as the specific cause) and that implementation anchors to function/comment landmarks instead.

- [ ] **Step 2: Amend §4** to state the confirmed firewall SSM parameter name (`cluster-civo/network/lb_firewall_id`, not `firewall_id`), and to state the civo DNS wait is bounded and non-fatal (with the reason: spec 110/060 aren't implemented within this spec's dependency chain).

- [ ] **Step 3: Amend §5** to add `gitops/bootstrap/values.yaml` and `gitops/bootstrap/templates/root-application.yaml` to the files/components list, with a one-line reason (the bootstrap chart is the pass-through hop for the new `--set` values, spec.md's original author missed it).

- [ ] **Step 4: Amend §9** to note that `shellcheck`/`bash -n` did not exist as a repo-wide gate before this change, and that the gate here is "no new warnings vs. the Task 0 baseline," not zero warnings.

- [ ] **Step 5: Commit**

```bash
git add specs/civo/045-argo-scripts-civo-branches/spec.md
git commit -m "civo-045: amend spec with line-drift, firewall param name, bootstrap chart scope, and shellcheck baseline corrections"
```

---

## Task 8: Real civo up/down validation (~0.15 USD, needs user go-ahead)

**Files:** none (evidence only).

- [ ] **Step 1: Ask the user before spending** — this brings up a real Civo cluster. Confirm before running.

- [ ] **Step 2: Run the civo baseline up**

```bash
PROVIDER=civo make up
```

Confirm the root Application reaches `Synced/Healthy` (acceptance criterion 2). Save the console output.

- [ ] **Step 3: Confirm the fast path on a second run**

```bash
PROVIDER=civo make argo-up
```

Expected: hits the "already Synced/Healthy" exit within `civo_wait_for_dns`'s bound, not stuck (acceptance criterion 1).

- [ ] **Step 4: Verify `TERMINATING_KINDS` filtering behavior for real**

```bash
kubectl api-resources --no-headers -o name | grep -E 'karpenter|cnpg'
```

Confirm which of `TERMINATING_KINDS` are actually absent, matching or correcting the assumption in Task 6 Step 4.

- [ ] **Step 4a: Note which Route 53 zone the down-script's DNS wait actually resolves on civo**

`provider.sh` sets `SUBDOMAIN=civo` on the civo path, so `argo-down.sh`'s Route 53 wait (unchanged, per spec §4) looks up a `civo.<root-domain>` zone rather than `lab.<root-domain>`. Record in the evidence file whether that zone exists yet at this point in the rollout (spec 002/persistent-civo territory) — if it doesn't, the wait's existing "WARNING - could not resolve hosted zone... skipping wait" non-fatal fallback should fire; confirm that's actually what happens rather than assuming it.

- [ ] **Step 5: Run `argo-down` and confirm the LB gate/DNS gate terminate cleanly**

```bash
PROVIDER=civo make argo-down
```

Confirm:
- `civo_backup` ran before disarm and (on this bare baseline) logged "nothing to back up."
- The LoadBalancer Service and the Civo LB are gone (`civo loadbalancer ls`) before the cascade completes (acceptance criterion 3).
- No token or bcrypt value printed anywhere in the output (acceptance criterion 5).

- [ ] **Step 6: Save evidence**

```bash
mkdir -p specs/civo/045-argo-scripts-civo-branches/evidence
# paste the console outputs from Steps 2/3/5 into:
#   specs/civo/045-argo-scripts-civo-branches/evidence/civo-up-down-run.md
git add specs/civo/045-argo-scripts-civo-branches/evidence/civo-up-down-run.md
git commit -m "civo-045: record civo up/down evidence"
```

---

## Task 9: AWS regression validation

**Files:** none (evidence only).

- [ ] **Step 1: Full AWS `argo-down`, then `argo-up`, to prove the extraction changed nothing end to end**

Raw traces to the scratchpad only — same secret/root-domain leak risk as Task 0.

```bash
bash -x scripts/argo-down.sh 2> /tmp/aws-fulldown.raw
bash -x scripts/argo-up.sh 2> /tmp/aws-fullup.raw
```

- [ ] **Step 2: Extract, redact, and review before anything is committed**

```bash
for f in aws-fulldown aws-fullup; do
  grep -E '^\+ (helm|aws|kubectl|dig) ' "/tmp/$f.raw" | sed -E \
      -e 's/(--set configs\.secret\.argocdServerAdminPassword=)[^ ]+/\1<redacted>/' \
      -e 's/(--names )\/[^ ]+/\1<redacted>/' \
      -e "s#(dig \+short )'?argo\.[^ ']+#\1<redacted-fqdn>#" \
    > "/tmp/$f.filtered"
done
cat /tmp/aws-fulldown.filtered /tmp/aws-fullup.filtered   # eyeball: no bcrypt hash, no root domain, no token
```

- [ ] **Step 3: Compare the up-trace's command sequence against the Task 0 fast-path baseline plus Task 1's post-extraction fast-path trace** — confirm the `helm`/`aws`/`kubectl` command lines the fast-path baseline does cover match exactly (the full run naturally includes more commands than the fast path).

- [ ] **Step 4: Copy the reviewed, filtered files into the repo and commit**

```bash
cp /tmp/aws-fulldown.filtered specs/civo/045-argo-scripts-civo-branches/evidence/aws-full-down.txt
cp /tmp/aws-fullup.filtered specs/civo/045-argo-scripts-civo-branches/evidence/aws-full-up.txt
git add specs/civo/045-argo-scripts-civo-branches/evidence/aws-full-down.txt specs/civo/045-argo-scripts-civo-branches/evidence/aws-full-up.txt
git commit -m "civo-045: record full AWS argo-down/argo-up regression evidence"
```

- [ ] **Step 5: Update spec.md §14 with execution evidence and set status to DONE** (per spec §13 definition of done), and update whatever index file tracks civo spec statuses (check `specs/civo/README.md` or `roadmap.md` for the pattern used by the CIVO-040/050 closures referenced in git log).

---

## Self-Review Notes

- **Spec coverage:** §3 (evidence/drift) → Task 7; §4 (design) → Tasks 1, 3, 4, 6; §5 (files) → Tasks 1, 2, 3, 4, 5, 6, amended in Task 7; §6 (steps 1–4) → Tasks 1–2 (step 1), 8 (steps 3–4); §8 (acceptance) → verified across Tasks 8–9; §9 (validation) → Task 0 baseline + every task's shellcheck/bash -n steps + Task 8 real-cloud run; §10 (AWS regression) → Task 9; §11 (rollback) → no new task needed, `civo_backup`'s fail-closed body already is the safety net spec asks for.
- **No placeholders:** every function body above is complete, real bash — nothing marked TODO. The one deliberately-approximate spot is Task 4 Step 1/2's SSM path names, which are flagged explicitly as "confirm against the live output" rather than assumed, because this plan cannot query AWS SSM itself.
- **Type/name consistency:** `RECOVERY_SNAPSHOT_HANDLE`, `RESERVED_IP`, `FIREWALL_ID`, `LAB_FQDN`, `ADMIN_PASSWORD_BCRYPT_HASH` are set once (in `aws_resolve_inputs`/`civo_resolve_inputs` or `aws_resolve_snapshot`/`civo_recovery_handle`) and read by name consistently in `install_argocd`/`aws_install_root_application`/`civo_install_root_application`/`civo_wait_for_dns` — no renaming drift between tasks.
