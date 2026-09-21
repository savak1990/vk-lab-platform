---
id: "SHARED-040"
title: "One provider file per provider in scripts/lib, so a third provider adds a file instead of a third arm to every branch"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Splitting provider.sh and cluster-down.sh's inline sweep along a function-set contract touches every caller that dispatches on PROVIDER; the contract and the collapsed call sites are enumerated below, but which functions already split cleanly versus need a genuinely new abstraction is a real judgment call"
effort_estimate: "One session (4-6 h)"
estimate_confidence: "medium"
depends_on: ["SHARED-039"]
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-040 — One provider file per provider in `scripts/lib`

## 1. Outcome and rationale

`scripts/lib/provider.sh` keeps only what every provider shares. Each
provider's own behavior - defaults, kubeconfig, TLS round-trip, cluster
lifecycle, leak sweep - lives in its own `scripts/lib/provider-<name>.sh`,
sourced by `provider.sh` after the shared code, by name. A third provider
(Hetzner) adds a third file with the same function set, instead of a third
`if`/`elif` arm inside every function `provider.sh` already has.

**Priority 3, optional.** The current `if [ "$PROVIDER" = civo ]` branches
work. This is a shape change ahead of Hetzner landing a third provider,
not a fix for anything broken with two.

## 2. The problem

`scripts/lib/provider.sh` is 364 lines. It holds, in one file:

- The `PROVIDER` defaults table, an `if [ "$PROVIDER" = "civo" ]`/`else`
  block at lines 10-28, setting `PROJECT_NAME`, `SUBDOMAIN`, `CLUSTER_DIR`,
  `CLUSTER_NAME`, `PERSISTENT_EXTRA_DIR`, `BOOTSTRAP_EXCLUDE`,
  `PERSISTENT_EXCLUDE`, and `BACKUP_SSM_LAYER` per provider. This is
  top-level code, not a function - it runs the instant the file is sourced.
- Three already-shared functions, each a single body with its own internal
  `if [ "$PROVIDER" = "civo" ]` branch: `cluster_exists` (lines 71-78,
  branch at 72), `configure_kubeconfig` (lines 107-133, branch at 112), and
  `configure_test_kubeconfig` (lines 135-165, branch at 140 - inverted, `!=
  "civo"`).
- Civo-only functions with no aws counterpart at all, called through an
  external `if [ "$PROVIDER" = civo ]` guard at their call site rather than
  being safe to call unconditionally: `civo_token` (line 40),
  `civo_export_tls_secret` (lines 296-317, guarded at
  `scripts/argo-down.sh` lines 47-49), and `civo_import_tls_secret` (lines
  325-364, guarded at `scripts/argo-up.sh` lines 163-165).
- The Postgres backup helpers (`backup_teardown` and its siblings, lines
  167-294), which are already provider-agnostic and stay shared.

Beyond `provider.sh` itself, `scripts/cluster-down.sh` holds a fourth thing
this spec's `sweep_leaks` contract is meant to cover: a single `if
[ "$PROVIDER" = "civo" ]`/`else` block, lines 55-210, that sweeps
provider-specific leaked resources after `terragrunt destroy` - Civo
cluster/firewall/volume/load-balancer names in the `civo` branch (55-96),
AWS instance/volume/NLB/ENI/security-group/launch-template/instance-profile
tag lookups in the `else` branch (100-208). This is not a function today;
it is 155 lines of inline top-level code in `cluster-down.sh`, which is why
this spec's scope includes that file, not only `provider.sh`.

`PROVIDER`-conditioned `= civo`/`!= aws`-shaped branch tests (re-verified
2026-09-20) exist across at least nine scripts that read `$PROVIDER`
directly - `scripts/argo-up.sh` (7: lines 157, 163, 292, 309, 321, 474,
558), `scripts/argo-down.sh` (5: lines 47, 73, 97, 225, 249),
`scripts/lib/provider.sh` (4: lines 10, 72, 112, 140),
`scripts/require-persistent.sh` (1: line 34), `scripts/cluster-down.sh` (1:
line 55), `scripts/generate-secrets.sh` (1), `scripts/lib/argo-state.sh` (1:
line 30), `scripts/status.sh` (1: line 59), and `scripts/verify-no-leaks.sh`
(1) - roughly two dozen in total, before counting
`scripts/gitops-render-check.sh`'s equivalent `target`/`t`-variable branches
(at least four: lines 164, 195, 221, 230), which condition on the same
civo-vs-aws split through a differently-named variable.

A third provider (Hetzner, tracked under `specs/hetzner/`) adds a third arm
to every one of those branches. `specs/hetzner/016-D-non-aws-generalisation/
spec.md` (HETZ-016) already reclassifies most of the `civo`-named branches
in `argo-up.sh`, `argo-down.sh`, `provider.sh`, and the eleven `eq
.Values.target "civo"` Helm sites as "non-AWS" rather than "civo" - it does
not yet give the script-side split a per-provider file shape, which is what
this spec adds.

## 3. Scope and non-goals

In scope:

- Splitting `scripts/lib/provider.sh` into a shared core plus
  `provider-aws.sh`/`provider-civo.sh`.
- Extracting `scripts/cluster-down.sh`'s inline leak-sweep block (lines
  55-210) into a `sweep_leaks` function in each provider file.
- Collapsing the dispatch-only `if [ "$PROVIDER" = civo ]` arms in
  `scripts/argo-up.sh`/`scripts/argo-down.sh` into direct calls.
- One `define` in the `Makefile` replacing its four duplicated
  `source scripts/lib/region.sh; source scripts/lib/provider.sh` lines.
- Naming the relationship to HETZ-016 explicitly (see §7 below).

Non-goals:

- Moving orchestration order out of `argo-up.sh` (that stays SHARED-041's
  job).
- Touching `gitops/` or any Helm template - `target`/`.Values.target`
  branches are HETZ-016's and SHARED-039's concern, not this one's.
- Writing `provider-hetzner.sh` itself - this spec only shapes the contract
  a third file would follow.
- Renaming `cluster-down.sh`'s remaining orchestration (the destroy call,
  the pre-destroy kubectl checks) - only the leak-sweep block moves.

## 4. Requirements

1. `scripts/lib/provider.sh` MUST keep only what is genuinely shared today:
   `use_isolated_kubeconfig`, `require_isolated_kubeconfig`,
   `persistent_exclude_filters`, and the Postgres backup helpers
   (`backup_teardown` and its siblings). It MUST still set
   `PROVIDER="${PROVIDER:-aws}"` at its own top, before sourcing anything -
   the provider file to source cannot be chosen otherwise - and it MUST then
   `source "scripts/lib/provider-${PROVIDER}.sh"` and call that file's
   `provider_defaults` immediately after sourcing it.
2. `scripts/lib/provider-aws.sh` and `scripts/lib/provider-civo.sh` MUST each
   define the same function set with the same signatures. Three of these
   split cleanly from their current single-body-with-an-internal-branch
   form: `cluster_exists`, `configure_kubeconfig`, `configure_test_kubeconfig`
   (today's bodies at `provider.sh` lines 71-78, 107-133, 135-165
   respectively). The rest are new abstractions replacing inline or
   civo-only code: `provider_defaults` (replacing the top-level `if`/`else`
   at lines 10-28; sets `PROJECT_NAME`, `SUBDOMAIN`, `CLUSTER_DIR`,
   `CLUSTER_NAME`, `PERSISTENT_EXTRA_DIR`, `BOOTSTRAP_EXCLUDE`,
   `PERSISTENT_EXCLUDE`, `BACKUP_SSM_LAYER`), `provider_token` (generalizing
   today's civo-only `civo_token`, a no-op on aws),
   `export_tls_secret`/`import_tls_secret` (generalizing today's civo-only
   `civo_export_tls_secret`/`civo_import_tls_secret`, no-ops on aws - aws has
   no equivalent today, so the aws bodies are new, empty functions, not a
   split of existing code), and `sweep_leaks` (extracting
   `cluster-down.sh`'s inline lines 55-210 into a real function per
   provider, called unconditionally from `cluster-down.sh` instead of
   guarded inline).
3. A provider file missing one of those functions MUST fail at source time,
   with a message naming the missing function and the provider - not at the
   first call site that happens to need it.
4. The `if [ "$PROVIDER" = civo ]` arms in `scripts/argo-up.sh` and
   `scripts/argo-down.sh` that only dispatch to a provider-specific function
   (not the ones that also branch on unrelated logic) MUST collapse to a
   direct call, now that the called function always exists for the active
   provider. This includes `scripts/argo-up.sh`'s `civo_import_tls_secret`
   call (lines 163-165) and `scripts/argo-down.sh`'s `civo_export_tls_secret`
   call (lines 47-49), which become unconditional `import_tls_secret`/
   `export_tls_secret` calls.
5. `scripts/cluster-down.sh`'s `if [ "$PROVIDER" = "civo" ]`/`else` block
   (lines 55-210) MUST collapse to one unconditional `sweep_leaks` call.
6. The `Makefile`'s four inline `source scripts/lib/region.sh; source
   scripts/lib/provider.sh` lines MUST become one `define` (or equivalent),
   used by all four targets.
7. `make -n` output for every target on both AWS and Civo MUST be identical
   before and after.
8. One real Civo lifecycle run (`persistent-up` through `cluster-down` or
   equivalent) MUST complete after the split, since `provider-civo.sh` is
   the file most of the moved logic actually exercises, and MUST include at
   least one run where `cluster-down.sh`'s sweep finds nothing to clean up
   (proving the unconditional `sweep_leaks` call is safe on a clean
   teardown, not only on one with leaks to find).

## 5. Implementation hints

- Start from `cluster_exists`, `configure_kubeconfig`, and
  `configure_test_kubeconfig` (provider.sh lines 71-165) - those already
  split cleanly into two provider-specific bodies with no new abstraction
  needed. The `PROVIDER` defaults table (lines 10-28) and
  `cluster-down.sh`'s sweep block (lines 55-210) are the two places that
  need a genuinely new function (`provider_defaults`, `sweep_leaks`)
  introduced where none exists today.
- `provider_token`, `export_tls_secret`, and `import_tls_secret` do not
  exist as no-op-on-aws functions today - `civo_token`,
  `civo_export_tls_secret`, and `civo_import_tls_secret` exist only on the
  civo side, called through an external guard. Writing an empty
  `provider-aws.sh` body for each is what lets `argo-up.sh`/`argo-down.sh`'s
  call sites drop their guard, not a rename of something that already has
  an aws counterpart.
- Note explicitly, in this spec's own commit or PR, the relationship to
  HETZ-016: whichever of the two lands first records the other as either
  superseded (if it already delivers the per-provider-file shape) or
  dependent (if it still needs this spec's split applied on top of its own
  branch reclassification). Do not let both specs silently reimplement the
  same file split.
- `cluster-down.sh`'s two branches are asymmetric in size (civo's is ~40
  lines, aws's is ~110) because AWS load-balancer-controller/Karpenter
  leave more untracked resource types behind than Civo's CLI does - moving
  each branch's body into its own provider file's `sweep_leaks` verbatim,
  without trying to unify their shape, is the safe first pass.

## 6. Testing / acceptance criteria

1. `provider-aws.sh` and `provider-civo.sh` each export the full function
   set from Requirement 2; sourcing either with one function commented out
   fails immediately with a clear message.
2. AWS and Civo `make -n` output identical before and after, for every
   target.
3. One real Civo lifecycle run passes end to end, including a `cluster-down`
   where `sweep_leaks` finds and reports zero leaks.
4. One real AWS lifecycle run (`bootstrap-up` through `cluster-up`/`argo-up`
   or equivalent) passes end to end, confirming the shared-core split did
   not regress the provider with fewer functions actually exercised by CI.
5. The commit or PR names HETZ-016 and records which spec now depends on, or
   supersedes, the other.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
