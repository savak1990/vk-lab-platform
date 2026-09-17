---
id: "CIVO-130"
title: "E2E test suite on Civo with a ServiceAccount-based read-only identity"
status: "READY"
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
updated: "2026-09-06"
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
- An `Environment` constructor alias.

Not in scope: new test cases. The Postgres test runs after CIVO-120 lands.

## 3. Current state / evidence

- `tests/e2e/framework/config.go:22-33` requires `--context`. `suite_test.go:33-41` builds `NewAWSEnvironment`. The implementation makes no AWS calls (`environment.go:62-115`).
- `Makefile:159-172` `test-kubeconfig` uses `eks-test-identity`. The `test` target passes `--context=$(PROJECT_NAME)-eks-test`.
- `gitops/templates/platform/aws/rbac/e2e-test-readonly.yaml` binds the Group `e2e-test-readonly` (EKS access entry mapping).

## 4. Design and contracts

- Hoist the RBAC file to `shared/rbac/e2e-test-readonly.yaml`. On civo, add a `ServiceAccount e2e-test` in namespace `e2e`. Bind it to the same ClusterRole/RoleBindings through a values-driven subject (aws: Group; civo: ServiceAccount).
- The `test-kubeconfig` civo branch does three steps. First, it runs `configure_kubeconfig` as cluster-admin. Second, it runs `kubectl create token e2e-test -n e2e --duration=1h`. Third, it writes a separate context `${PROJECT_NAME}-civo-test` with that token into the kubeconfig. `make test` uses that context.
- Rename `NewAWSEnvironment` to `NewClusterEnvironment`. Keep `NewAWSEnvironment` as a thin alias. This is a one-line change, and it keeps the history readable.

## 5. Files/components affected

`Makefile`, `scripts/lib/provider.sh`, `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml`, `gitops/values.yaml`, `tests/e2e/framework/environment.go`, `tests/e2e/suite_test.go`.

## 6. Implementation steps

1. Hoist the RBAC file. The golden aws diff must be empty.
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

The AWS `make test` flags are unchanged. The alias keeps the constructor.

## 11. Rollout and rollback/recovery

Revert the change. There is no data risk.

## 12. Risks and unresolved questions

- Token TTL vs test duration: 1 h is ample.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
