---
id: "CIVO-130"
title: "E2E test suite on Civo with a ServiceAccount-based read-only identity"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Small Go and Make changes reusing an interface designed for this"
effort_estimate: "One session (3–4 h)"
estimate_confidence: "high"
depends_on: ["CIVO-045", "CIVO-060"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-17"
completed: null
---

# CIVO-130 — E2E tests on Civo

## 1. Outcome and rationale

`PROVIDER=civo make test` runs the existing Ginkgo suite against the Civo
cluster. The suite uses a read-only ServiceAccount token. The assertions
need no Go changes.

## 2. Scope and non-goals

In scope:

- `Makefile` test dispatch.
- The `test-kubeconfig` civo branch.
- The RBAC manifest for the SA on civo.
- The `Environment` constructor rename.

Not in scope: new test cases. The Postgres test runs after CIVO-120 lands.

## 3. Current state / evidence

- `tests/e2e/framework/config.go` requires `--context`. `suite_test.go` builds `NewAWSEnvironment`. The implementation makes no AWS calls (`environment.go`).
- `Makefile` `test-kubeconfig` uses `eks-test-identity` on aws and exits 1 on civo. The `test` target passes `--context=$(PROJECT_NAME)-eks-test` for both providers.
- The RBAC file is already hoisted to `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml` and renders on civo. It binds only the Group `e2e-test-readonly` (EKS access entry mapping), which nothing maps on civo.
- `E2E_INSECURE_TLS=1` (`--insecure-skip-tls-verify`) already exists for the staging issuer.

## 4. Design and contracts

- On civo, add `Namespace e2e` and `ServiceAccount e2e-test` (sync-wave 1). Bind it to the same ClusterRole/RoleBindings through the `platform.e2eTestSubject` helper (aws/local: Group; civo: ServiceAccount, with no `apiGroup`).
- The `test-kubeconfig` civo branch does three steps. First, it runs `configure_kubeconfig` as cluster-admin. Second, it runs `kubectl create token e2e-test -n e2e --duration=1h`. Third, it writes a separate context `${PROJECT_NAME}-civo-test` with that token into the kubeconfig. `make test` uses that context.
- Rename `AWSEnvironment`/`NewAWSEnvironment` to `ClusterEnvironment`/`NewClusterEnvironment`. No alias: `suite_test.go` is the only caller (operator decision, 2026-09-17).

## 5. Files/components affected

`Makefile`, `scripts/lib/provider.sh`, `scripts/gitops-render-check.sh`, `gitops/templates/_helpers.tpl`, `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml`, `tests/golden/gitops-aws` (comment only), `tests/e2e/framework/environment.go`, `tests/e2e/suite_test.go`.

## 6. Implementation steps

1. Make the RBAC subject target-aware. The golden aws diff may change only in comments.
2. Make the Make and lib changes. `PROVIDER=civo make test-argocd` must pass. `make test` may fail only on tests whose components are not yet on civo. Record which tests fail.
3. Run a negative test: the SA token cannot list Secrets cluster-wide.

## 7. Dependencies and blockers

045 (argo-up on civo), 060 (routes for `ServiceURL`).

## 8. Acceptance criteria

- `PROVIDER=civo make test-argocd` is green. `make test` is green after 120 and 160 are done (tracked in 150).
- `make test` on AWS is unchanged (same flags, same context name).
- The SA token scope is limited to the read-only role.

## 9. Validation

Offline: `go vet`, `go build ./tests/...`, golden diff. Real cloud: one civo run (~cents).

## 10. AWS regression protection

The AWS `make test` flags are unchanged (`make -n` output identical).

## 11. Rollout and rollback/recovery

Revert the change. There is no data risk.

## 12. Risks and unresolved questions

- Token TTL vs test duration: 1 h is ample.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-17 — IN_PROGRESS. Offline implementation on branch `civo-130-e2e-tests`:
  - `platform.e2eTestSubject` helper; civo-only `Namespace e2e` + `ServiceAccount e2e-test`; the 3 RoleBindings use the helper. `gitops-render-check.sh` requires both new objects on civo and forbids them on local.
  - `make gitops-check` passes. The aws golden diff is the file header comment only (2 ClusterRole files); no rendered field changed.
  - `configure_test_kubeconfig` in `scripts/lib/provider.sh`; `E2E_CONTEXT` in `Makefile`. `make -n test-argocd`: aws `--context=vk-lab-platform-eks-test` (unchanged), civo `--context=vk-civo-lab-civo-test`.
  - Go rename without alias; `go vet ./tests/...` and `go build ./tests/...` pass. No test assertion changed (only the constructor call in `suite_test.go`).
  - Token scope, structural proof: `e2e-test-readonly` is reached only through namespace-scoped RoleBindings (`cnpg-system`, `observability`, `argocd`), never a ClusterRoleBinding, so a cluster-wide Secret list is impossible by construction. The live `auth can-i` check is still pending.
  - Real-cloud run (§6 steps 2–3) not done yet: no civo cluster was up.
- 2026-09-17 — **live civo run.** Branch pushed; `PROVIDER=civo TARGET_REVISION=civo-130-e2e-tests make full-up` exited 0 (root Synced/Healthy, DNS resolved).
  - `PROVIDER=civo make test` exited 0 with the context `vk-civo-lab-civo-test`: `Ran 4 of 4 Specs in 4.311 seconds`, 4 passed, 0 failed (argocd, grafana, postgres ×2). `E2E_INSECURE_TLS` was not needed on the prod issuer.
  - `kubectl auth whoami` on the test context: `system:serviceaccount:e2e:e2e-test`.
  - Negative checks, all `no`: `list secrets -A`, `get secrets -n kube-system`, `create pods -n cnpg-system`, `delete clusters.postgresql.cnpg.io -n cnpg-system`. Positive control: `get secrets -n cnpg-system` is `yes`.
  - All §8 acceptance criteria met. AWS was not run live; its render and `make test` command line are unchanged.
