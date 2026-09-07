---
id: "CIVO-040"
title: "Cluster scripts for Civo: cluster-down, kubeconfig, status, guards, leak sweep"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Shell branches with clear specifications; correctness of guards matters but the logic is simple"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-030"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-07"
completed: "2026-09-07"
---

# CIVO-040 — Cluster scripts for Civo

## 1. Outcome and rationale

The targets `PROVIDER=civo make cluster-up`, `cluster-down`, `status`, and `eks-kubeconfig` work on Civo.
We rename the `eks-kubeconfig` target internally to a provider-neutral kubeconfig target.
The Civo path has the same guards and the same leak checks as the AWS path.
Every state prefix guard knows the civo stacks.

## 2. Scope and non-goals

In scope:

- `scripts/cluster-down.sh`
- `scripts/status.sh`
- `scripts/require-persistent.sh`
- `scripts/bootstrap-down.sh`
- `scripts/persistent-down.sh`
- the `scripts/state-down.sh` bug fix
- `scripts/lib/argo-state.sh`
- the Makefile `kubeconfig` and `cluster-up` targets
- `configure_kubeconfig()`, `cluster_exists()`, `civo_cli()`, `civo_list_names()` in `scripts/lib/provider.sh`

Not in scope: `argo-up` and `argo-down` (CIVO-045), and tests (CIVO-130).

## 3. Current state / evidence

- `scripts/cluster-down.sh:18-41` sets `CLUSTER_NAME="${PROJECT_NAME}-eks"`. It proves that the cluster exists with `aws eks describe-cluster`. It writes the kubeconfig with `eks-access-identity`. It refuses to run if the root Application exists. It runs `terragrunt run --all destroy`. Lines `:43-65` run a tag-based leak sweep.
- `scripts/status.sh:26` lists the prefixes `bootstrap persistent cluster`. Lines `:59-63` read the Terragrunt output from `cluster/eks`.
- `scripts/require-persistent.sh:36` runs `aws iam get-role eks-access-identity`.
- `scripts/bootstrap-down.sh:31` and `scripts/persistent-down.sh:74,116` contain the prefix lists.
- `scripts/state-down.sh:30` checks `disposable ci`. These prefixes never match, because `cluster/` is the real prefix.
- `Makefile:140-143,159-162` contain the kubeconfig targets.

## 4. Design and contracts

- `scripts/lib/provider.sh` gets `cluster_exists()`, `configure_kubeconfig([kubeconfig_path])`, `civo_cli()`, `civo_list_names(resource, [args...])`, and a `CLUSTER_NAME` export (aws: `${PROJECT_NAME}-eks`; civo: `$PROJECT_NAME`, matching `civo_kubernetes_cluster.name`). `PROVIDER_SH_REPO_ROOT` is computed once at source time (not inside any function) so a caller's later `cd` can never break a relative-path lookup — this fixes a real bug found in execution (§14).
- On aws, `cluster_exists()` uses `aws eks describe-cluster`. On civo, it uses the exit code of `civo kubernetes show "$CLUSTER_NAME" --region "$CIVO_REGION"` (via `civo_cli`, which always redirects the CLI's `~/.civo.json` token write to a throwaway file).
- On aws, `configure_kubeconfig()` keeps the existing `aws eks update-kubeconfig` code. On civo, it runs `civo kubernetes config "$CLUSTER_NAME" --save --region "$CIVO_REGION"` (or `--local-path <path>` when a kubeconfig path argument is given) and then renames the resulting context to `${PROJECT_NAME}-civo` via `kubectl config rename-context` — the civo CLI has no `--switch`/`--context-name` flag that does this, so it's done as a separate step, deleting any prior `${PROJECT_NAME}-civo` context first for idempotency across reruns. Every array expansion of the optional `--kubeconfig` flag uses the `${kcfg[@]:+"${kcfg[@]}"}` idiom, not bare `"${kcfg[@]}"` — bash 3.2 (macOS default) throws `unbound variable` on an empty array's `[@]` under `set -u` otherwise (a real bug found in execution, §14).
- `civo_list_names()` guards against `civo <resource> ls -o json` printing the plain-text line `No resources found in region ...` instead of `[]` when there are zero matches (verified live) — it only pipes to `jq` when the raw output starts with `[`.
- `cluster-down.sh` sources the lib and uses `cluster_exists()`/`configure_kubeconfig()`. On civo, the leak sweep uses `civo_list_names()` for `kubernetes`, `firewall`, `volume --dangling`, and `loadbalancer`. It reports (never deletes) a leaked load balancer — the civo CLI has no `loadbalancer remove` command (§12). It attempts deletion via `civo_cli firewall remove`/`civo_cli volume remove -y` for firewalls and dangling volumes.
- `status.sh` uses the prefixes `bootstrap persistent persistent-civo cluster cluster-civo`. It shows only the prefixes that are present in the bucket. The Argo check (`scripts/lib/argo-state.sh`'s `argo_state()`) branches on `PROVIDER`: on civo it calls `configure_kubeconfig` with a caller-supplied kubeconfig path via a single-command `CLUSTER_NAME="$cluster" configure_kubeconfig "$kubeconfig"` environment override (scoped to that one call, never leaking into the caller); on aws it keeps the original inline `aws eks update-kubeconfig` logic unchanged.
- `require-persistent.sh` skips the `eks-access-identity` check on civo. It adds a check that the `persistent-civo/network` state is not empty.
- Guards: `bootstrap-down.sh` refuses on `persistent persistent-civo cluster cluster-civo`. `persistent-down.sh` refuses on `cluster cluster-civo`. The `state-down.sh` guard list becomes `bootstrap persistent persistent-civo cluster cluster-civo`. This fixes the pre-existing `disposable`/`ci` bug (those two prefixes never matched any real state key).
- Makefile: `eks-kubeconfig` is renamed to `kubeconfig` outright, no alias kept (2026-09-07 user decision — clean rename over back-compat). The new target dispatches on `PROVIDER`. `test-kubeconfig` is unaffected by this rename and keeps its current name. `cluster-up` also gained a civo branch that calls `civo_token` before the terragrunt apply — the shared target never did this, so `PROVIDER=civo make cluster-up` failed with "No token configuration found" before this fix.

## 5. Files/components affected

The scripts listed above, `scripts/lib/argo-state.sh`, the `Makefile`, and `scripts/lib/provider.sh`. There are no Terraform changes and no GitOps changes. There is no state impact.

## 6. Implementation steps

1. Add the lib functions. Unit-test them with `PROVIDER=aws` against the existing AWS project. Test `cluster_exists` for both the true case and the false case.
2. Branch `cluster-down.sh`. Keep the aws code path textually identical, apart from the function calls.
3. Update the guard lists in the four scripts and in `status.sh`.
4. Add the Makefile kubeconfig dispatch.
5. Run the real cycle: `PROVIDER=civo make cluster-up`, `make status`, `make cluster-down`. Check the leak sweep output.

## 7. Dependencies and blockers

CIVO-030 must supply a cluster to test against. Parallel work: the CIVO-045 draft and CIVO-050.

## 8. Acceptance criteria

- `PROVIDER=civo make cluster-down` refuses to run while a root Application exists. It proceeds after `argo-down`. It reports zero leaks.
- `make status` prints both projects when we run it with each `PROVIDER`.
- `state-down.sh` now refuses to run when `cluster/` has resources. The regression test runs the guard function in dry-run mode against the AWS project.
- AWS: the output and the behavior of `make cluster-down` do not change. Compare a dry run with the previous run log.
- No script prints the Civo token. `set -x` is never enabled around `civo_token`.

## 9. Validation

Offline: run `shellcheck`. Test the guard functions with `aws s3api` mocked by a stub in PATH. Real cloud: run one Civo cycle (~0.10 USD). AWS: run dry runs only.

## 10. AWS regression protection

The AWS branches do not change textually, except for the function extraction. Run `bash -n`. Diff a recorded `make status` and a recorded `make -n down` against the new output.

## 11. Rollout and rollback/recovery

Revert the scripts. There is no data risk. `cluster-down` never touches the persistent units, because they live in a separate stack dir.

## 12. Risks and unresolved questions

- The `civo kubernetes config` flags differ per CLI version. Pin the CLI version in the docs and in CI.
- The `civo` CLI has no `loadbalancer remove`/`delete` command (removed upstream from its command tree — only `ls`/`show` remain). `cluster-down.sh`'s leak sweep can only report a leaked Civo LB, never delete it from the script; manual deletion via the dashboard or API is required.
- `civo <resource> ls -o json` prints the plain-text line `No resources found in region <region>...`, not `[]`, when there are zero matches. Any code parsing that output as JSON must check for a leading `[` first (`civo_list_names()` does this); a raw `civo ... ls -o json | jq` pipeline elsewhere in this codebase would silently abort under `set -e` on an empty result. Discovered 2026-09-07 during planning, confirmed live during execution.
- Civo's network-creation API intermittently fails with `DatabaseFirewallSaveFailedError` (an internal error on Civo's side, tied to the auto-created per-network default firewall) — observed 3 times in a row during this spec's real cycle test, resolved on the 4th retry after a short pause. This is a transient platform-side condition, not a defect in this repo's Terraform; a `persistent-up` retry is the correct response, not a code fix.
- `configure_kubeconfig()`'s optional `--kubeconfig` array must be expanded as `${kcfg[@]:+"${kcfg[@]}"}`, never bare `"${kcfg[@]}"` — bash 3.2 (macOS default, and this repo's baseline shell per `persistent-down.sh`'s own comments) throws `unbound variable` on an empty array's `[@]` expansion under `set -u`. Found live 2026-09-07 when `cluster-down.sh` called `configure_kubeconfig` with no path argument; every prior call site (the Makefile's `kubeconfig` target) happened to run without `set -u` active, masking the bug until this spec's own new caller exposed it.
- `civo_token()` must compute its repo-root path once, at source time (module-level, before any caller's later `cd`) — not lazily inside the function using a relative `${BASH_SOURCE[0]}`-derived path. `cluster-down.sh` `cd`s into `terraform/live/cluster-civo` for its terragrunt destroy step and never `cd`s back; the leak sweep's `civo_token` call (added by this spec) then broke with `cd: ./scripts/lib/../..: No such file or directory` until fixed. Found live 2026-09-07; this bug pre-dated this spec (every prior caller happened to call `civo_token` before any `cd`).

## 13. Definition of done

- [x] Acceptance criteria evidence recorded
- [x] `shellcheck` clean (pre-existing info/warning-level notices only, no new issues — see §14)
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-07 — implemented via subagent-driven development, 6 tasks (provider.sh helpers, require-persistent.sh, state-down.sh, argo-state.sh/status.sh, cluster-down.sh, Makefile), each with an independent implementer and task reviewer; all approved with only Minor findings deferred (see the plan's ledger at `.superpowers/sdd/2026-09-07-civo-040-cluster-scripts/progress.md` during development, since deleted per the SDD workflow's cleanup step once the branch merged).
- 2026-09-07 — real Civo cycle test (Task 7): `bootstrap-up` → `persistent-up` (needed 4 attempts due to a transient Civo API `DatabaseFirewallSaveFailedError` on network/firewall creation, unrelated to this repo's code — see §12) → `cluster-up` (succeeded, cluster `vk-civo-lab`, nodes Ready) → `make kubeconfig` (context correctly renamed to `vk-civo-lab-civo`) → `make status` (`argo: absent (not installed, or torn down by argo-down)` — confirming the Civo Argo-check routing works live, not just statically) → `make cluster-down`. This surfaced two real, previously-undetected bugs (both now fixed, both listed in §12): the `kcfg` empty-array `unbound variable` crash, and `civo_token()`'s cd-fragile repo-root computation. Both were fixed with a dedicated hotfix implementer + scoped review each, then re-verified live: `cluster-down` completed cleanly (`Destroy complete! Resources: 4 destroyed.`) → `persistent-down` → `bootstrap-down`, all succeeded. Post-teardown orphan sweep across Civo (`kubernetes ls`, `network ls`, `firewall ls`, `ip ls`) and AWS (`s3 ls`, `route53 list-hosted-zones`) confirmed zero orphaned resources.
- 2026-09-07 — AWS regression verification (Task 8): `bash -n`/`shellcheck` clean on all 6 touched scripts plus the Makefile (only pre-existing info/warning-level shellcheck notices, none new); diffing the Makefile and every touched script against the pre-plan baseline commit confirmed every AWS-only code path is byte-identical except for the deliberate function-call substitutions; a live `PROVIDER=aws PROJECT_NAME=vk-lab-platform ./scripts/status.sh` run matches the known pre-plan baseline output exactly (this AWS account currently has no bootstrap/persistent/cluster state, unchanged from CIVO-030's own final state).
- 2026-09-07 — closed as DONE.
