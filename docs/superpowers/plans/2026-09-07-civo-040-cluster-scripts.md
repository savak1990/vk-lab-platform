# CIVO-040 — Cluster scripts for Civo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `PROVIDER=civo make cluster-up`, `cluster-down`, `status` (including the Argo line), and `make kubeconfig` all work for Civo, with the AWS code paths textually unchanged.

**Architecture:** Push all AWS/Civo branching into `scripts/lib/provider.sh` (`cluster_exists()`, `configure_kubeconfig()`, `civo_cli()`, `civo_list_names()`, `CLUSTER_NAME`) so every call site branches through one function call instead of duplicating provider logic. `scripts/lib/argo-state.sh` gets the same treatment for the one AWS-only call it still makes.

**Tech Stack:** bash, `civo` CLI, `aws` CLI, `jq`, `kubectl`, GNU Make.

**Spec:** `specs/civo/040-civo-cluster-scripts/spec.md`

## Global Constraints

- AWS code paths in every touched script must remain textually identical except for the function-call substitution — this is the AWS-regression acceptance criterion.
- No script may print the Civo token. `civo_token()` (already in `provider.sh`) masks it in GitHub Actions logs and stays the only place that decrypts it.
- `civo` CLI writes its active token to `~/.civo.json` on disk as a side effect of *any* invocation, including one using `CIVO_TOKEN` — confirmed against `civo/cli`'s `config/config.go`. Every `civo` CLI call this plan adds redirects that write to a throwaway file via `CIVO_CONFIG`, never the real `~/.civo.json`.
- `civo <resource> ls -o json` prints the plain-text line `No resources found in region <region>...` instead of `[]` when a region has zero matches — confirmed live against the real account. Piping that straight into `jq` under `set -e` would abort the script instead of reporting zero leaks. Every list call in this plan checks the raw output starts with `[` before parsing it as JSON.
- `civo kubernetes config` has no `--context-name` flag — the context name is always the cluster's own (lowercased) name. Getting `${PROJECT_NAME}-civo` requires `kubectl config rename-context` after the civo CLI call.
- `civo` CLI has **no `loadbalancer remove` command** (removed from the command tree upstream). A leaked Civo LB can only be reported, never deleted, from these scripts.
- Every script that reads `$PROJECT_NAME` must `source scripts/lib/provider.sh` **before** any local `PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"`-style default, and must not set its own such default at all — `provider.sh` already exports the correct per-provider default. Getting this order backwards silently forces the aws project name even under `PROVIDER=civo` (this caused a real accidental-AWS-resource incident earlier this session).
- `PROJECT_NAME=vk-civo-lab CIVO_REGION=LON1` are already exported by `scripts/lib/provider.sh`/`scripts/lib/region.sh`.
- Do not touch `argo-up`/`argo-down` (CIVO-045) or test suites (CIVO-130) — out of scope.

## Spec correction carried into this plan

Spec §2 names the new function `civo_kubeconfig()`; §4 names it `configure_kubeconfig()` (provider-branching, called for both providers). This plan uses **`configure_kubeconfig()`**, matching §4's actual design. Task 9 fixes §2 to match. Spec §5's file list also omits `scripts/lib/argo-state.sh` and the Makefile's `cluster-up` recipe even though §1's own outcome sentence and §4's "Argo check uses `configure_kubeconfig`" require both — Task 9 corrects the file list too.

---

### Task 1: `scripts/lib/provider.sh` — cluster identity + civo CLI helpers

**Files:**
- Modify: `scripts/lib/provider.sh` (append after the existing `civo_token()` function)

**Interfaces:**
- Produces: `CLUSTER_NAME` (exported — `${PROJECT_NAME}-eks` on aws, `$PROJECT_NAME` on civo), `civo_cli()` (any `civo` invocation, args passed through, token-write redirected), `civo_list_names(resource, [extra civo-cli args...])` (echoes one name per line, or nothing, never raises on an empty result), `cluster_exists()` (returns 0/1), `configure_kubeconfig([kubeconfig_path])` (merges/writes kubeconfig, sets current context; writes to the given path or the default if omitted).
- Consumes: `civo_token()` (existing), `LAB_REGION`/`CIVO_REGION` (from `scripts/lib/region.sh`, sourced by every caller before this file).

- [ ] **Step 1: Add `CLUSTER_NAME` export to the existing provider branch**

Edit the `if [ "$PROVIDER" = "civo" ]; then ... else ... fi` block (lines 8–22):

```bash
if [ "$PROVIDER" = "civo" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-civo-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-civo}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster-civo}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-persistent-civo}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-acm}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc}"
else
  export PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
  export SUBDOMAIN="${SUBDOMAIN:-lab}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster}"
  export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-eks}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-}"
fi
```

Civo's `civo_kubernetes_cluster.name` is `var.project` (see `terraform/modules/civo-k8s/main.tf`), so `CLUSTER_NAME` on civo is exactly `$PROJECT_NAME`.

- [ ] **Step 2: Append `civo_cli()`, `civo_list_names()`, `cluster_exists()`, `configure_kubeconfig()`**

```bash
# Every civo CLI invocation writes its active token back to ~/.civo.json as
# a side effect (confirmed in civo/cli's config.go, even for a CIVO_TOKEN-
# only invocation) - CIVO_CONFIG redirects that write to a throwaway file so
# the decrypted token never lands in a real dotfile on disk. `|| status=$?`
# (not a bare call) keeps `set -e` from skipping the cleanup below on failure.
civo_cli() {
  local tmp status=0
  tmp="$(mktemp)"
  CIVO_CONFIG="$tmp" civo "$@" || status=$?
  rm -f "$tmp"
  return "$status"
}

# `civo <resource> ls -o json` prints the plain-text line "No resources
# found in region ..." instead of `[]` when there are zero matches (verified
# live) - piping that into jq under `set -e` would abort the caller instead
# of reporting zero results, so the shape is checked before parsing.
civo_list_names() {
  local resource="$1"
  shift
  local raw
  raw="$(civo_cli "$resource" ls -o json --region "$CIVO_REGION" "$@" 2>/dev/null || true)"
  case "$raw" in
    \[*) echo "$raw" | jq -r '.[].name' ;;
  esac
}

cluster_exists() {
  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    civo_cli kubernetes show "$CLUSTER_NAME" --region "$CIVO_REGION" >/dev/null 2>&1
  else
    aws eks describe-cluster --name "$CLUSTER_NAME" --region "$LAB_REGION" >/dev/null 2>&1
  fi
}

# Merges this cluster's kubeconfig into the given path (or the default
# kubeconfig / $KUBECONFIG if no path is given) and switches the current
# context to it. On civo, the civo CLI always names the context after the
# cluster's own (lowercased) name - there is no --context-name flag - so the
# context is renamed to "${PROJECT_NAME}-civo" afterward for a name stable
# across cluster recreations. Deleting the destination context first guards
# a second run against the same cluster: kubectl config rename-context fails
# if the destination name already exists.
configure_kubeconfig() {
  local kubeconfig="${1:-}"
  local kcfg=()
  [ -n "$kubeconfig" ] && kcfg=(--kubeconfig "$kubeconfig")

  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    if [ -n "$kubeconfig" ]; then
      civo_cli kubernetes config "$CLUSTER_NAME" --save --local-path "$kubeconfig" --region "$CIVO_REGION" >/dev/null
    else
      civo_cli kubernetes config "$CLUSTER_NAME" --save --region "$CIVO_REGION" >/dev/null
    fi
    local raw_context
    raw_context="$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]')"
    kubectl "${kcfg[@]}" config delete-context "${PROJECT_NAME}-civo" >/dev/null 2>&1 || true
    kubectl "${kcfg[@]}" config rename-context "$raw_context" "${PROJECT_NAME}-civo" >/dev/null
    kubectl "${kcfg[@]}" config use-context "${PROJECT_NAME}-civo" >/dev/null
  else
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "$CLUSTER_NAME" \
      --role-arn "$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)" \
      "${kcfg[@]}" >/dev/null
  fi
  kubectl "${kcfg[@]}" config set-context --current --namespace=default >/dev/null
}
```

- [ ] **Step 3: Shellcheck the file**

Run: `shellcheck scripts/lib/provider.sh`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/lib/provider.sh
git commit -m "civo-040: add cluster_exists/configure_kubeconfig/civo_cli/civo_list_names to provider.sh"
```

---

### Task 2: `scripts/require-persistent.sh` — skip AWS-only check, add Civo network check

**Files:**
- Modify: `scripts/require-persistent.sh` (whole file)

**Interfaces:**
- Consumes: `PROVIDER`, `PROJECT_NAME` (from `provider.sh`, Task 1).

- [ ] **Step 1: Source `provider.sh` before computing `BUCKET`, drop the local `PROJECT_NAME` default**

Replace lines 6–8:
```bash
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
```
with:
```bash
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
BUCKET="${PROJECT_NAME}-tf-state"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"
```
`provider.sh` must run first: it exports the correct per-provider `PROJECT_NAME` default, and a local `:-vk-lab-platform` fallback set before it would win under `PROVIDER=civo` (it does not, since bash's `:-` only fires on unset/empty — but sourcing `provider.sh` first removes any doubt, and matches the pattern `persistent-down.sh` already uses correctly).

- [ ] **Step 2: Replace the `eks-access-identity` check with a provider branch**

Replace the final block (the `if ! aws iam get-role --role-name eks-access-identity ...` check) with:
```bash
if [ "$PROVIDER" = "civo" ]; then
  civo_keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "persistent-civo/network/" --region "$LAB_REGION" \
    --query "Contents[?ends_with(Key, 'terraform.tfstate')].Key" --output text)

  civo_total=0
  if [ -n "$civo_keys" ] && [ "$civo_keys" != "None" ]; then
    for key in $civo_keys; do
      aws s3api get-object --bucket "$BUCKET" --key "$key" --region "$LAB_REGION" "$TMP_DIR/state.json" >/dev/null
      count=$(jq '.resources | length' "$TMP_DIR/state.json")
      civo_total=$((civo_total + count))
    done
  fi

  if [ "$civo_total" -eq 0 ]; then
    echo "Civo network not found under persistent-civo/network/ in s3://$BUCKET. Run 'make persistent-up' first." >&2
    exit 1
  fi
else
  # terraform/modules/eks looks this up by fixed name (account-global, not
  # state-tracked in this project's bucket) - check it explicitly here so
  # cluster-up fails with a clear message instead of a raw data-source error.
  if ! aws iam get-role --role-name eks-access-identity >/dev/null 2>&1; then
    echo "eks-access-identity not found. Run 'make account-up' first." >&2
    exit 1
  fi
fi
```

- [ ] **Step 3: Shellcheck and syntax-check**

Run: `shellcheck scripts/require-persistent.sh && bash -n scripts/require-persistent.sh`
Expected: clean.

- [ ] **Step 4: Regression dry-run against the real AWS project**

Run: `PROVIDER=aws PROJECT_NAME=vk-lab-platform ./scripts/require-persistent.sh; echo "exit=$?"`
Expected: `exit=1` with the pre-existing `Persistent-lifecycle resources not found...` message (this AWS account currently has no persistent state), proving the `else` branch is reached correctly.

- [ ] **Step 5: Commit**

```bash
git add scripts/require-persistent.sh
git commit -m "civo-040: require-persistent.sh checks persistent-civo/network on civo instead of eks-access-identity"
```

---

### Task 3: `scripts/state-down.sh` — fix the dead guard-prefix bug

**Files:**
- Modify: `scripts/state-down.sh:30`

- [ ] **Step 1: Fix the prefix list**

Change `for prefix in bootstrap persistent disposable ci; do` to `for prefix in bootstrap persistent persistent-civo cluster cluster-civo; do`. `disposable` and `ci` never matched any real state key (the real disposable prefix is `cluster/`) — this guard has been silently inert since it was written.

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/state-down.sh && shellcheck scripts/state-down.sh`

- [ ] **Step 3: Regression dry-run**

Run: `PROJECT_NAME=vk-lab-platform ./scripts/state-down.sh`
Expected: `s3://vk-lab-platform-tf-state does not exist. Nothing to do.` (the bucket doesn't currently exist, post CIVO-030 teardown) — proves the guard-list edit didn't touch the earlier existence check.

- [ ] **Step 4: Commit**

```bash
git add scripts/state-down.sh
git commit -m "civo-040: fix state-down.sh's dead guard prefixes (disposable/ci never matched real state keys)"
```

---

### Task 4: `scripts/lib/argo-state.sh` + `scripts/status.sh` — Civo-aware Argo check

**Files:**
- Modify: `scripts/lib/argo-state.sh:25-50` (`argo_state()`)
- Modify: `scripts/status.sh` (source order)

**Interfaces:**
- Consumes: `configure_kubeconfig()`, `civo_token()`, `PROVIDER` (Task 1).

- [ ] **Step 1: Branch `argo_state()` on `PROVIDER`**

Replace the body of `argo_state()` (current lines 30–38) with:
```bash
argo_state() {
  local cluster="${1:?argo_state: cluster name required}"
  local kubeconfig="${2:?argo_state: kubeconfig path required}"
  local sync_health app_count

  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    if ! CLUSTER_NAME="$cluster" configure_kubeconfig "$kubeconfig" >/dev/null 2>&1 \
      || ! kubectl --kubeconfig "$kubeconfig" cluster-info --request-timeout=5s >/dev/null 2>&1; then
      echo "unknown  (cluster unreachable)"
      return
    fi
  else
    local role_arn
    role_arn="$(argo_access_role_arn)"
    [ -n "$role_arn" ] || { echo "unknown  (eks-access-identity not found)"; return; }

    if ! aws eks update-kubeconfig --name "$cluster" --region "$LAB_REGION" \
      --alias "$cluster" --role-arn "$role_arn" --kubeconfig "$kubeconfig" >/dev/null 2>&1 \
      || ! kubectl --kubeconfig "$kubeconfig" cluster-info --request-timeout=5s >/dev/null 2>&1; then
      echo "unknown  (cluster unreachable)"
      return
    fi
  fi

  if ! kubectl --kubeconfig "$kubeconfig" get application root -n argocd >/dev/null 2>&1; then
    echo "absent   (not installed, or torn down by argo-down)"
    return
  fi

  sync_health="$(kubectl --kubeconfig "$kubeconfig" get application root -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  app_count="$(kubectl --kubeconfig "$kubeconfig" get applications -n argocd \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "present  (root ${sync_health:-unknown}, $app_count Application(s) managed)"
}
```
`CLUSTER_NAME="$cluster" configure_kubeconfig "$kubeconfig"` is a one-command environment override (not the `VAR=$(cmd) other_cmd` anti-pattern) — it scopes `CLUSTER_NAME` to that single invocation only, leaving the caller's global `CLUSTER_NAME` untouched, which matters since `status.sh`/`clusters.sh` may loop over more than one cluster.

- [ ] **Step 2: Fix `status.sh`'s `PROJECT_NAME` ordering and source `provider.sh`**

Replace lines 8–9:
```bash
PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
BUCKET="${PROJECT_NAME}-tf-state"
```
with:
```bash
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
BUCKET="${PROJECT_NAME}-tf-state"
```
(`provider.sh` must run before `region.sh`, matching the fixed order from Task 2 — move the existing `source .../lib/region.sh` line to right after this.)

`status.sh` already branches on `PROVIDER` for `CLUSTER_NAME` (lines 58–62, added in CIVO-030) — leave that block as-is; `argo-state.sh` now reads `PROVIDER` from the environment `provider.sh` exports.

- [ ] **Step 3: Shellcheck and syntax-check**

Run: `shellcheck scripts/lib/argo-state.sh scripts/status.sh && bash -n scripts/lib/argo-state.sh scripts/status.sh`

- [ ] **Step 4: Regression check against the real AWS project**

Run: `PROVIDER=aws PROJECT_NAME=vk-lab-platform ./scripts/status.sh`
Expected: same output shape as before this change (no persistent/cluster state, `argo: unknown (cluster not up)`), proving the aws branch in `argo_state()` still behaves identically when reached.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/argo-state.sh scripts/status.sh
git commit -m "civo-040: argo_state() and status.sh route Civo through configure_kubeconfig"
```

---

### Task 5: `scripts/cluster-down.sh` — provider dispatch + Civo leak sweep

**Files:**
- Modify: `scripts/cluster-down.sh` (whole file restructured; AWS branch content preserved verbatim)

**Interfaces:**
- Consumes: `cluster_exists()`, `configure_kubeconfig()`, `civo_cli()`, `civo_list_names()`, `CLUSTER_NAME`, `CLUSTER_DIR`, `PROJECT_NAME` (Task 1).

- [ ] **Step 1: Replace the header to source `provider.sh` first and use the new functions**

```bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/provider.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/region.sh"

if cluster_exists; then
  configure_kubeconfig
```

This drops the old `PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"` line entirely (provider.sh owns the default) and the old `CLUSTER_NAME="${PROJECT_NAME}-eks"` line (provider.sh exports it), and replaces the raw `if aws eks describe-cluster ...`/`aws eks update-kubeconfig ...`/`kubectl config set-context` lines with the two function calls. Everything from the old `if ! kubectl cluster-info ...` line through the closing `fi`/`else`/`echo`/`fi` stays **exactly as it was**.

- [ ] **Step 2: Leave the `terragrunt run --all destroy` and `LEAK_COUNT=0` lines unchanged**

They already use `${CLUSTER_DIR:-cluster}`, which `provider.sh` always sets — the `:-cluster` fallback is now inert but harmless.

- [ ] **Step 3: Wrap the existing AWS leak-sweep body in a provider branch, add the Civo branch**

```bash
if [ "$PROVIDER" = "civo" ]; then
  civo_token

  LEAKED_CLUSTERS="$(civo_list_names kubernetes | grep -x -- "$PROJECT_NAME" || true)"
  if [ -n "$LEAKED_CLUSTERS" ]; then
    echo "CLUSTER-DOWN: leaked Civo cluster still present after destroy: $LEAKED_CLUSTERS" >&2
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # cluster/lb firewalls are Disposable-lifecycle (created alongside the
  # cluster under cluster-civo/network) - if terragrunt destroy above
  # succeeded these should already be gone. Genuine leak check, not
  # expected output on a healthy run.
  LEAKED_FIREWALLS="$(civo_list_names firewall | grep -x -e "${PROJECT_NAME}-k8s" -e "${PROJECT_NAME}-lb" || true)"
  if [ -n "$LEAKED_FIREWALLS" ]; then
    echo "CLUSTER-DOWN: leaked Civo firewall(s), deleting: $LEAKED_FIREWALLS" >&2
    for fw in $LEAKED_FIREWALLS; do
      civo_cli firewall remove "$fw" -y --region "$CIVO_REGION" >/dev/null 2>&1 || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # --dangling limits this to volumes whose owning cluster is already gone,
  # so a still-attached persistent volume on a live cluster is never touched.
  LEAKED_VOLUMES="$(civo_list_names volume --dangling | grep -- "^${PROJECT_NAME}" || true)"
  if [ -n "$LEAKED_VOLUMES" ]; then
    echo "CLUSTER-DOWN: leaked Civo dangling volume(s), deleting: $LEAKED_VOLUMES" >&2
    for vol in $LEAKED_VOLUMES; do
      civo_cli volume remove "$vol" -y --region "$CIVO_REGION" >/dev/null 2>&1 || true
    done
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi

  # civo CLI has no `loadbalancer remove` command (removed upstream - only
  # ls/show remain), so a leaked LB can only be reported here.
  LEAKED_LBS="$(civo_list_names loadbalancer | grep -- "^${PROJECT_NAME}" || true)"
  if [ -n "$LEAKED_LBS" ]; then
    echo "CLUSTER-DOWN: WARNING - leaked Civo load balancer(s), cannot delete via CLI (no 'civo loadbalancer remove' command exists): $LEAKED_LBS" >&2
    echo "CLUSTER-DOWN: delete manually via the Civo dashboard or API." >&2
    LEAK_COUNT=$((LEAK_COUNT + 1))
  fi
else
  # <every line of the original aws leak-sweep body, verbatim, unchanged -
  # LEAKED_INSTANCES through the Karpenter instance-profile sweep. Copy from
  # the file as it exists before this edit; do not retype from memory.>
fi
```

- [ ] **Step 4: Leave the closing `if [ "$LEAK_COUNT" -eq 0 ]` block unchanged**

- [ ] **Step 5: Shellcheck and syntax-check**

Run: `shellcheck scripts/cluster-down.sh && bash -n scripts/cluster-down.sh`

- [ ] **Step 6: Commit**

```bash
git add scripts/cluster-down.sh
git commit -m "civo-040: cluster-down.sh dispatches on PROVIDER, adds Civo leak sweep"
```

---

### Task 6: Makefile — rename `eks-kubeconfig` to `kubeconfig`, wire Civo token into `cluster-up`

**Files:**
- Modify: `Makefile:1` (`.PHONY`), `Makefile:148-154` (`cluster-up`), `Makefile:164-182` (`eks-kubeconfig` block)
- Search: repo-wide for stray `eks-kubeconfig` references

- [ ] **Step 1: Update `.PHONY`**

Change `eks-kubeconfig` to `kubeconfig` on line 1.

- [ ] **Step 2: Give `cluster-up` a Civo branch that wires in `CIVO_TOKEN`**

The shared `cluster-up` recipe runs raw `terragrunt ... apply`, which never calls `civo_token()` — this was worked around by hand earlier this session (`CIVO_TOKEN="$(./scripts/secret-decrypt.sh civo-token)" PROVIDER=civo make cluster-up`) and needs a permanent fix, following the same `ifeq ($(PROVIDER),civo)` pattern the `persistent-up` target already uses:

```makefile
## Creates the disposable cluster (system node group + addons, or firewall +
## k3s cluster on civo). Fails fast (naming `make persistent-up`) if the
## Persistent layer doesn't exist yet - never creates it (constitution §17).
## Run `make argo-up` after this to install Argo CD and the platform.
ifeq ($(PROVIDER),civo)
cluster-up:
	./scripts/require-persistent.sh
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; civo_token; cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve'
else
cluster-up:
	./scripts/require-persistent.sh
	cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve
endif
```

- [ ] **Step 3: Replace the `eks-kubeconfig` target block with `kubeconfig`**

```makefile
## Points local kubectl context at the disposable cluster. On aws, every
## kubectl call re-assumes eks-access-identity via --role-arn (baked into
## the generated kubeconfig's exec plugin), so access never depends on
## whether you or GitHub Actions created the cluster. On civo, merges the
## cluster's kubeconfig and renames its context to $(PROJECT_NAME)-civo (the
## civo CLI has no way to name the context directly). A manual/human
## convenience target only - up/down/argo-up/argo-down/cluster-down/status
## each configure their own kubeconfig internally instead of depending on
## this, since the cluster may not exist yet (or anymore) when those run,
## and a Make prerequisite can't be conditional.
## Usage: make kubeconfig
kubeconfig:
ifeq ($(PROVIDER),civo)
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; configure_kubeconfig'
else
	aws eks update-kubeconfig --name $(PROJECT_NAME)-eks --region $(REGION) --alias $(PROJECT_NAME)-eks \
		--role-arn "$$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)"
	kubectl config set-context --current --namespace=default
endif
```

- [ ] **Step 4: Grep the repo for stray `eks-kubeconfig` references and update each**

Run: `grep -rn "eks-kubeconfig" --include="*.md" --include="*.yml" --include="*.yaml" --include="Makefile" .`
Replace `make eks-kubeconfig` with `make kubeconfig` in every hit outside the Makefile block just rewritten. No backward-compat alias (explicit 2026-09-07 user decision, already recorded in the CIVO-040 spec).

- [ ] **Step 5: Verify the AWS branches are unchanged**

Run: `make -n kubeconfig` and `make -n cluster-up` (default `PROVIDER=aws`)
Expected: identical recipe text to before this change (compare against `git show HEAD:Makefile`).

- [ ] **Step 6: Commit**

```bash
git add Makefile <any files touched in step 4>
git commit -m "civo-040: rename eks-kubeconfig to kubeconfig, wire civo_token into cluster-up"
```

---

### Task 7: Real Civo cycle test

**Files:** none (verification only).

- [ ] **Step 1: Confirm with the user before spending money**

This creates a real Civo cluster (~0.10 USD per the spec's own validation estimate). Use `AskUserQuestion` to confirm.

- [ ] **Step 2: Bring up persistent + cluster**

```bash
PROVIDER=civo make persistent-up   # no-op if already up
PROVIDER=civo make cluster-up
```

- [ ] **Step 3: Verify `make kubeconfig` and `make status`**

```bash
PROVIDER=civo make kubeconfig
kubectl config current-context   # expect: vk-civo-lab-civo
kubectl get nodes                # expect: 3 Ready nodes
PROVIDER=civo make status        # expect: argo: absent (not installed...) - no Argo yet, CIVO-045 - not "unknown"
```

If `argo:` shows `unknown (cluster unreachable)` instead of `absent`, that's a real bug in Task 4 to investigate before proceeding, not something to work around.

- [ ] **Step 4: Verify `make cluster-down` and its leak sweep**

```bash
PROVIDER=civo make cluster-down
```

Expected: `CLUSTER-DOWN: no leaked disposable-lifecycle resources found.`, exit 0.

- [ ] **Step 5: Post-teardown orphan sweep**

```bash
civo kubernetes ls --region LON1
civo firewall ls --region LON1
civo loadbalancer ls --region LON1
civo volume ls --region LON1
```

Expect nothing named `vk-civo-lab*`.

- [ ] **Step 6: Tear down persistent again only if it was freshly created for this test**

Ask the user first — never destroy Persistent-lifecycle resources without confirmation.

---

### Task 8: AWS regression verification

- [ ] **Step 1: Dry-run diff against pre-change behavior**

```bash
git stash
make -n down > /tmp/down-before.txt
PROJECT_NAME=vk-lab-platform ./scripts/status.sh > /tmp/status-before.txt 2>&1 || true
git stash pop
make -n down > /tmp/down-after.txt
PROJECT_NAME=vk-lab-platform ./scripts/status.sh > /tmp/status-after.txt 2>&1 || true
diff /tmp/down-before.txt /tmp/down-after.txt
diff /tmp/status-before.txt /tmp/status-after.txt
```
Expected: no diff.

- [ ] **Step 2: `bash -n` every touched script**

```bash
bash -n scripts/cluster-down.sh scripts/status.sh scripts/require-persistent.sh scripts/state-down.sh scripts/lib/provider.sh scripts/lib/argo-state.sh
```

---

### Task 9: Close out the spec

**Files:**
- Modify: `specs/civo/040-civo-cluster-scripts/spec.md`

- [ ] **Step 1: Fix the §2/§4 function-name inconsistency and the §5 file list**

§2: change `civo_kubeconfig() in scripts/lib/provider.sh` to `configure_kubeconfig(), cluster_exists(), civo_cli(), civo_list_names() in scripts/lib/provider.sh`. §5: add `scripts/lib/argo-state.sh` and the Makefile's `cluster-up` recipe to the affected-files list.

- [ ] **Step 2: Add §12 risk entries**

> The `civo` CLI has no `loadbalancer remove`/`delete` command (removed upstream — only `ls`/`show` remain). `cluster-down.sh`'s leak sweep can only report a leaked Civo LB, never delete it.
>
> `civo <resource> ls -o json` prints plain text (`No resources found...`), not `[]`, when a region has zero matches — every list call in this codebase must check for a leading `[` before parsing as JSON.
>
> Both discovered 2026-09-07 during CIVO-040.

- [ ] **Step 3: Update frontmatter and DoD**

`status: "READY"` → `"DONE"`, `updated`/`completed` → `"2026-09-07"`. Check off §13's DoD boxes. Add a §14 entry summarizing Task 7/8's real-cycle and regression results.

- [ ] **Step 4: Commit**

```bash
git add specs/civo/040-civo-cluster-scripts/spec.md
git commit -m "civo-040: close out spec with execution evidence"
```
