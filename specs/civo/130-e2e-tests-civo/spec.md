---
id: "CIVO-130"
title: "E2E test suite on Civo with a ServiceAccount-based read-only identity"
status: "DRAFT"
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
cluster using a read-only ServiceAccount token, without Go changes to the
assertions.

## 2. Scope and non-goals

In scope: `Makefile` test dispatch, `test-kubeconfig` civo branch, RBAC
manifest for the SA on civo, an `Environment` constructor alias. Not in
scope: new test cases (the Postgres test runs once CIVO-120 lands).

## 3. Current state / evidence

- `tests/e2e/framework/config.go:22-33` requires `--context`; `suite_test.go:33-41` builds `NewAWSEnvironment`; the implementation makes no AWS calls (`environment.go:62-115`).
- `Makefile:159-172` `test-kubeconfig` uses `eks-test-identity`; `test` passes `--context=$(PROJECT_NAME)-eks-test`.
- `gitops/templates/platform/aws/rbac/e2e-test-readonly.yaml` binds Group `e2e-test-readonly` (EKS access entry mapping).

## 4. Design and contracts

- Hoist the RBAC file to `shared/rbac/e2e-test-readonly.yaml`; on civo add a `ServiceAccount e2e-test` in namespace `e2e` bound to the same ClusterRole/RoleBindings via a values-driven subject (aws: Group; civo: ServiceAccount).
- `test-kubeconfig` civo: `configure_kubeconfig` as cluster-admin, then `kubectl create token e2e-test -n e2e --duration=1h` and write a separate context `${PROJECT_NAME}-civo-test` with that token into the kubeconfig; `make test` uses that context.
- Rename `NewAWSEnvironment` to `NewClusterEnvironment` with `NewAWSEnvironment` kept as a thin alias (one-line change, keeps history readable).

## 5. Files/components affected

`Makefile`, `scripts/lib/provider.sh`, `gitops/templates/platform/shared/rbac/e2e-test-readonly.yaml`, `gitops/values.yaml`, `tests/e2e/framework/environment.go`, `tests/e2e/suite_test.go`.

## 6. Implementation steps

1. RBAC hoist; golden aws diff empty.
2. Make/lib changes; `PROVIDER=civo make test-argocd` passes; `make test` fails only on tests whose components are not yet on civo (record which).
3. Negative: the SA token cannot list Secrets cluster-wide.

## 7. Dependencies and blockers

045 (argo-up on civo), 060 (routes for `ServiceURL`).

## 8. Acceptance criteria

- `PROVIDER=civo make test-argocd` green; `make test` green once 120 and 160 are done (tracked in 150).
- `make test` on AWS unchanged (same flags, same context name).
- SA token scope limited to the read-only role.

## 9. Validation

Offline: `go vet`, `go build ./tests/...`, golden diff. Real cloud: civo run (~cents).

## 10. AWS regression protection

AWS `make test` flags unchanged; alias keeps the constructor.

## 11. Rollout and rollback/recovery

Revert. No data risk.

## 12. Risks and unresolved questions

- Token TTL vs test duration: 1 h is ample.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
