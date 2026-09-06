---
id: "CIVO-040"
title: "Cluster scripts for Civo: cluster-down, kubeconfig, status, guards, leak sweep"
status: "READY"
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
updated: "2026-09-06"
completed: null
---

# CIVO-040 — Cluster scripts for Civo

## 1. Outcome and rationale

`PROVIDER=civo make cluster-up`, `cluster-down`, `status`, `eks-kubeconfig`
(renamed internally to a provider-neutral kubeconfig target) work on Civo
with the same guards and leak checks the AWS path has, and every state
prefix guard understands the civo stacks.

## 2. Scope and non-goals

In scope: `scripts/cluster-down.sh`, `scripts/status.sh`,
`scripts/require-persistent.sh`, `scripts/bootstrap-down.sh`,
`scripts/persistent-down.sh`, `scripts/state-down.sh` bug fix, Makefile
kubeconfig targets, `scripts/lib/provider.sh` `civo_kubeconfig()`.
Not in scope: `argo-up`/`argo-down` (CIVO-045), tests (CIVO-130).

## 3. Current state / evidence

- `scripts/cluster-down.sh:18-41`: `CLUSTER_NAME="${PROJECT_NAME}-eks"`, `aws eks describe-cluster` existence proof, kubeconfig with `eks-access-identity`, refusal if root Application exists, `terragrunt run --all destroy`, `:43-65` tag-based leak sweep.
- `scripts/status.sh:26` prefixes `bootstrap persistent cluster`; `:59-63` Terragrunt output from `cluster/eks`.
- `scripts/require-persistent.sh:36` `aws iam get-role eks-access-identity`.
- `scripts/bootstrap-down.sh:31`, `scripts/persistent-down.sh:74,116` prefix lists.
- `scripts/state-down.sh:30` checks `disposable ci` which never match (`cluster/` is the real prefix).
- `Makefile:140-143,159-162` kubeconfig targets.

## 4. Design and contracts

- `scripts/lib/provider.sh`: `cluster_exists()` (aws: `describe-cluster`; civo: `civo kubernetes show "$PROJECT_NAME" --region "$CIVO_REGION"` exit code), `configure_kubeconfig()` (aws: existing; civo: `civo kubernetes config "$PROJECT_NAME" --save --switch --region ...` into `$KUBECONFIG` or default file, context renamed to `${PROJECT_NAME}-civo`), `CLUSTER_DIR`.
- `cluster-down.sh`: source lib; use the functions; civo leak sweep via `civo kubernetes ls`, `civo loadbalancer ls`, `civo volume ls` filtered by name prefix `${PROJECT_NAME}` and by the persistent network; warn, do not delete persistent volumes; delete orphan LBs and firewalls only if named `${PROJECT_NAME}-*` and not the persistent ones.
- `status.sh`: prefixes `bootstrap persistent persistent-civo cluster cluster-civo` (only those present in the bucket); Argo check uses `configure_kubeconfig`.
- `require-persistent.sh`: skip the `eks-access-identity` check on civo; add a check that `persistent-civo/network` state is non-empty.
- Guards: `bootstrap-down.sh` refuses on `persistent persistent-civo cluster cluster-civo`; `persistent-down.sh` refuses on `cluster cluster-civo`; `state-down.sh` guard list becomes `bootstrap persistent persistent-civo cluster cluster-civo` (fixes the pre-existing `disposable` bug).
- Makefile: `eks-kubeconfig` kept as an alias of a new `kubeconfig` target that dispatches on `PROVIDER`.

## 5. Files/components affected

Scripts listed above; `Makefile`; `scripts/lib/provider.sh`. No Terraform or GitOps changes; no state impact.

## 6. Implementation steps

1. Add lib functions; unit-test them with `PROVIDER=aws` against the existing AWS project (`cluster_exists` true/false).
2. Branch `cluster-down.sh`; keep the aws code path textually identical apart from the function calls.
3. Update guard lists in the four scripts and `status.sh`.
4. Makefile kubeconfig dispatch.
5. Run the real cycle: `PROVIDER=civo make cluster-up`, `make status`, `make cluster-down`, check leak sweep output.

## 7. Dependencies and blockers

CIVO-030 for a cluster to test against. Parallel: CIVO-045 drafting, CIVO-050.

## 8. Acceptance criteria

- `PROVIDER=civo make cluster-down` refuses while a root Application exists; proceeds after `argo-down`; reports zero leaks.
- `make status` prints both projects when run with each `PROVIDER`.
- `state-down.sh` now refuses when `cluster/` has resources (regression test against the AWS project by dry-run of the guard function).
- AWS: `make cluster-down` output and behavior unchanged (compare a dry run and the previous run log).
- No script prints the Civo token; `set -x` is never enabled around `civo_token`.

## 9. Validation

Offline: `shellcheck`; guard functions tested with `aws s3api` mocked by a stub in PATH. Real cloud: one Civo cycle (~0.10 USD). AWS: dry runs only.

## 10. AWS regression protection

AWS branches unchanged textually except function extraction; `bash -n`; a recorded `make status` and `make -n down` diff.

## 11. Rollout and rollback/recovery

Revert scripts. No data risk; `cluster-down` never touches persistent units (separate stack dir).

## 12. Risks and unresolved questions

- `civo kubernetes config` flags per CLI version; pin the CLI version in docs and CI.

## 13. Definition of done

- [ ] Acceptance criteria evidence recorded
- [ ] `shellcheck` clean
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
