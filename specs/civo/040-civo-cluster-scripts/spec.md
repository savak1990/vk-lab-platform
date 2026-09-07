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
- the Makefile kubeconfig targets
- `civo_kubeconfig()` in `scripts/lib/provider.sh`

Not in scope: `argo-up` and `argo-down` (CIVO-045), and tests (CIVO-130).

## 3. Current state / evidence

- `scripts/cluster-down.sh:18-41` sets `CLUSTER_NAME="${PROJECT_NAME}-eks"`. It proves that the cluster exists with `aws eks describe-cluster`. It writes the kubeconfig with `eks-access-identity`. It refuses to run if the root Application exists. It runs `terragrunt run --all destroy`. Lines `:43-65` run a tag-based leak sweep.
- `scripts/status.sh:26` lists the prefixes `bootstrap persistent cluster`. Lines `:59-63` read the Terragrunt output from `cluster/eks`.
- `scripts/require-persistent.sh:36` runs `aws iam get-role eks-access-identity`.
- `scripts/bootstrap-down.sh:31` and `scripts/persistent-down.sh:74,116` contain the prefix lists.
- `scripts/state-down.sh:30` checks `disposable ci`. These prefixes never match, because `cluster/` is the real prefix.
- `Makefile:140-143,159-162` contain the kubeconfig targets.

## 4. Design and contracts

- `scripts/lib/provider.sh` gets `cluster_exists()`, `configure_kubeconfig()`, and `CLUSTER_DIR`. On aws, `cluster_exists()` uses `describe-cluster`. On civo, it uses the exit code of `civo kubernetes show "$PROJECT_NAME" --region "$CIVO_REGION"`. On aws, `configure_kubeconfig()` keeps the existing code. On civo, it runs `civo kubernetes config "$PROJECT_NAME" --save --switch --region ...` into `$KUBECONFIG` or the default file. It renames the context to `${PROJECT_NAME}-civo`.
- `cluster-down.sh` sources the lib and uses the functions. On civo, the leak sweep runs `civo kubernetes ls`, `civo loadbalancer ls`, and `civo volume ls`. It filters the results by the name prefix `${PROJECT_NAME}` and by the persistent network. It warns about persistent volumes. It does not delete persistent volumes. It deletes orphan LBs and firewalls only if their name is `${PROJECT_NAME}-*` and they are not the persistent ones.
- `status.sh` uses the prefixes `bootstrap persistent persistent-civo cluster cluster-civo`. It shows only the prefixes that are present in the bucket. The Argo check uses `configure_kubeconfig`.
- `require-persistent.sh` skips the `eks-access-identity` check on civo. It adds a check that the `persistent-civo/network` state is not empty.
- Guards: `bootstrap-down.sh` refuses on `persistent persistent-civo cluster cluster-civo`. `persistent-down.sh` refuses on `cluster cluster-civo`. The `state-down.sh` guard list becomes `bootstrap persistent persistent-civo cluster cluster-civo`. This fixes the pre-existing `disposable` bug.
- Makefile: `eks-kubeconfig` is renamed to `kubeconfig` outright, no alias kept (2026-09-07 user decision — clean rename over back-compat). The new target dispatches on `PROVIDER`. `test-kubeconfig` is unaffected by this rename and keeps its current name.

## 5. Files/components affected

The scripts listed above, the `Makefile`, and `scripts/lib/provider.sh`. There are no Terraform changes and no GitOps changes. There is no state impact.

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

## 13. Definition of done

- [ ] Acceptance criteria evidence recorded
- [ ] `shellcheck` clean
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
