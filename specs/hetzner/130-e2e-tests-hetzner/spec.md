---
id: "HETZ-130"
title: "E2E test suite on Hetzner through the ServiceAccount token context"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One Make arm and one values entry on top of CIVO-130's SA-token path"
effort_estimate: "Half a session (1–2 h)"
estimate_confidence: "high"
depends_on: ["HETZ-045", "HETZ-060", "CIVO-130"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-130 — E2E tests on Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make test` runs the existing Ginkgo suite against the
Hetzner cluster with a read-only ServiceAccount token. A self-managed k3s
has no cloud IAM mapping, so the SA-token path from CIVO-130 is the only
option. No Go changes.

Read `specs/civo/130-e2e-tests-civo/spec.md` first.

## 2. Scope and non-goals

In scope:
- The `hetzner` arm of `test-kubeconfig` and `test` in the `Makefile`.
- The RBAC subject values for `target: hetzner`.
- `E2E_INSECURE_TLS` for CI runs with the staging issuer.

Not in scope: new test cases. The Postgres test runs after HETZ-120.

## 3. Current state / evidence

- CIVO-130 hoists `shared/rbac/e2e-test-readonly.yaml` with a values-driven
  subject (aws: Group; civo: ServiceAccount `e2e-test` in `e2e`) and adds
  a `test-kubeconfig` civo branch that writes context
  `${PROJECT_NAME}-civo-test`.
- `Makefile:204-207` still has the civo `test-kubeconfig` stub at the
  package baseline; CIVO-130 replaces it.
- The `test` target passes `--context=$(PROJECT_NAME)-eks-test` as a
  literal (review C trap). CIVO-130 is expected to parametrize it as
  `$(TEST_CONTEXT)`. If it did not, this spec does it: one variable with
  three defaults, no behaviour change on aws.
- `tests/e2e/framework/config.go` exposes `--insecure-skip-tls-verify`
  through `E2E_INSECURE_TLS` (CIVO-140 §4).

## 4. Design and contracts

- `TEST_CONTEXT` in the `Makefile`: `$(PROJECT_NAME)-eks-test` on aws,
  `$(PROJECT_NAME)-civo-test` on civo, `$(PROJECT_NAME)-hetzner-test` on
  hetzner. The aws and civo strings are unchanged.
- `test-kubeconfig` on hetzner: run `configure_kubeconfig` (SSH fetch,
  HETZ-040), then `kubectl create token e2e-test -n e2e --duration=1h`,
  then write the `${PROJECT_NAME}-hetzner-test` context. Same three steps
  as civo; after HETZ-016 the branch is `[ "$PROVIDER" != aws ]` with the
  context name from `provider.sh`.
- RBAC subject values: `rbac.e2eSubject.kind: ServiceAccount` for
  hetzner, identical to civo.
- The `ServiceURL` helper resolves `argo.hetzner.<root-domain>`; the LB IP
  changes per `make up`, so the suite must resolve DNS at run time, which
  it already does.

## 5. Files/components affected

`Makefile` (`TEST_CONTEXT`, `test-kubeconfig` arm), `scripts/lib/provider.sh`
(context name default), `gitops/values.yaml` (hetzner rbac subject).

## 6. Implementation steps

1. Add the values entry. Golden diffs for aws and civo must be empty.
2. Add the Make arm. `make -n test` on aws and civo must be byte-identical
   to before.
3. Run `PROVIDER=hetzner make test-argocd`. Must pass.
4. Run `PROVIDER=hetzner make test`. Record which tests fail because their
   component is not yet on hetzner.
5. Negative test: the SA token cannot list Secrets cluster-wide.

## 7. Dependencies and blockers

HETZ-045 (`argo-up` on hetzner), HETZ-060 (routes for `ServiceURL`),
CIVO-130 (SA-token path, RBAC hoist).

## 8. Acceptance criteria

- `PROVIDER=hetzner make test-argocd` is green. `make test` is green after
  HETZ-120 and HETZ-160 (tracked in HETZ-150).
- `make test` on aws and civo is unchanged: same flags, same context
  names.
- The SA token scope is limited to the read-only role.

## 9. Validation

Offline: `go vet`, `go build ./tests/...`, golden diffs, `make -n test`
diff. Real cloud: one hetzner run, cents.

## 10. AWS regression protection

`make -n test` byte-identical on aws. Civo: `make -n test` byte-identical
on civo; one `PROVIDER=civo make test-argocd` run recorded.

## 11. Rollout and rollback/recovery

Revert. No data risk.

## 12. Risks and unresolved questions

- Token TTL 1 h against test duration: ample.
- If CIVO-130 chose a different variable name than `TEST_CONTEXT`, use
  that name; do not introduce a second one.

## 13. Definition of done

- [ ] Make arm, values, evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
