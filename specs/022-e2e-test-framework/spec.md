# 021 — Go E2E Test Framework

**Complexity:** Medium
**Risk:** Low — no AWS credentials, no persistent state; the framework itself is a library, not something that mutates infrastructure.
**Estimated cost:** ~1.5–2 days · AWS runtime cost: none — this spec is pure Go tooling, reused by (not run standalone in) specs 019 and 022.
**Recommended model:** Sonnet — well-documented Go/Ginkgo patterns, low architectural ambiguity.
**Depends on:** none directly; consumed by 018-ci-full-lifecycle-validation and 022-ci-kind-integration-test.
**Lifecycle class(es) touched:** none — a test framework, not infrastructure.

## Scope

Introduces the platform's E2E verification framework, per ADR 0007: a Go/Ginkgo v2/Gomega test suite under `tests/e2e/`, with an `Environment` abstraction so the same service-level assertions run unmodified against a kind cluster (spec 023) or real EKS (spec 019).

- `tests/e2e/suite_test.go` — the Ginkgo suite entry point, explicit kubeconfig-context selection, Ginkgo parallel-process configuration.
- Per-service test files: `postgres_test.go`, `grafana_test.go`, and equivalents for Kafka, Prometheus, Argo CD (added incrementally as each service's checks are defined — this spec establishes the pattern via Postgres and Grafana in full; the others follow the same shape).
- `tests/e2e/framework/`: `config.go` (test configuration/flags), `kubernetes.go` (client-go wiring, explicit context), `environment.go` (the `Environment` interface and its `kind`/`aws` implementations), `endpoints.go` (how to resolve a service's reachable address per environment), `portforward.go` (kind-side port-forward helper), `diagnostics.go` (failure-path diagnostics: pod logs/events dump on test failure).

This spec is a library and CLI entry point (`go test ./tests/e2e/...` via Ginkgo), not a workflow. Specs 018 and 022 each invoke it against their own cluster; neither duplicates its assertions.

Excludes: the workflows/Makefile targets that create the cluster this suite runs against (020, 022) or that stand up the full AWS environment (018) — this spec only owns what happens once a cluster already exists and Argo CD has reconciled it. Also excludes any test of business application code (constitution §1 — there is none in this repository).

## Requirements

1. The primary test framework MUST be Go using Ginkgo v2 and Gomega — not Bash. Bash MAY remain for orchestration/bootstrap (creating the cluster, invoking `go test`), but MUST NOT contain the platform's actual test assertions.
2. Kubernetes access MUST use `client-go`; PostgreSQL access MUST use `pgx`; HTTP API checks MUST use `net/http` — no additional client libraries introduced without a stated reason.
3. The suite MUST expose an `Environment` interface abstracting *how* a test reaches a service, at minimum:
   ```go
   type Environment interface {
       KubernetesClient() kubernetes.Interface
       ServiceURL(service string) string
       PostgresDSN(cluster string) string
   }
   ```
   with a `kind` implementation (using `kubectl port-forward`-equivalent tunneling, or direct `ClusterIP` access from within the cluster's network reach) and an `aws` implementation (real ingress hostname, real Postgres connection details). Service test files MUST express assertions against this interface only — never branch on "am I running against kind or aws" inside a test body.
4. The framework MUST accept an explicit Kubernetes context (or equivalent explicit cluster-selection mechanism) and MUST fail fast if none is supplied — a run MUST NOT silently default to whatever context happens to be current in the invoking shell's kubeconfig, so a test run can never accidentally target an unrelated cluster.
5. Tests MUST NOT install Postgres, Kafka, Grafana, or any other platform service themselves — Argo CD owns installation (constitution §6); this suite only verifies what Argo has already reconciled.
6. Readiness checks MUST use Gomega `Eventually()` with a sensible timeout/poll interval, never an arbitrary `sleep`. If a service is already healthy when a check begins, the check MUST proceed immediately rather than waiting out a fixed poll interval regardless of actual state.
7. Postgres checks MUST verify actual usability, not just a `Running` pod: operator ready, PostgreSQL CR/cluster ready, expected Service exists, credentials Secret exists, a TCP/database connection succeeds, admin authentication succeeds, `SELECT 1` succeeds, and admin permission is verified via a temporary create/drop operation (created and dropped by the test itself, never left behind).
8. Grafana checks MUST verify actual usability: operator/controller ready, Grafana resource/deployment ready, Service reachable, `/api/health` returns success, and — where a datasource/config expectation exists — that it's present. Prefer API/health verification over browser-based rendering unless a concrete UI behavior genuinely requires a browser.
9. Equivalent functional (not just `Running`) checks MUST be designed for every other platform service already planned in the architecture (Kafka, Prometheus, Argo CD itself) following the same "verify actual usability" pattern as Requirements 7–8, added incrementally as each service's spec matures — this spec establishes the pattern and its first two full implementations, not a closed list.
10. Independent services' tests MUST be able to run in parallel via Ginkgo's own parallel-process support, using a fixed, bounded process count — start with `-p 2` (this spec covers two services at inception: Postgres, Grafana) and revisit the number once a third service's suite exists, rather than building a tunable config knob for a suite this small.
11. Ginkgo labels MUST allow running a single service's tests in isolation (e.g. `ginkgo --label-filter=postgres`), so `make test-postgres`-style targets (spec 023) can invoke exactly one service's suite without running the rest.

## Implementation hints

- Keep `framework/environment.go`'s `Environment` interface small and grow it only when a real test needs a new capability — resist adding methods speculatively. `PostgresDSN` is a deliberate exception (Postgres is this spec's first stateful-service check), not a pattern to repeat: before writing Kafka's test, reconsider whether a single bespoke method per data store (`PostgresDSN`, then a future `KafkaBootstrapServers`, etc.) is still the right shape, or whether a general `ConnectionInfo(service string) map[string]string` avoids growing one accessor per service.
- `framework/diagnostics.go` is worth building early: on any test failure, dump the relevant pod's recent logs and events before the test exits, since a failed `Eventually()` with no diagnostic output is the single most common source of wasted CI-debugging time.
- For the `kind` `Environment` implementation, prefer talking to services via their in-cluster `ClusterIP` address from a test-runner pod (or the GitHub Actions runner's direct network reach into the kind cluster) over spawning `kubectl port-forward` subprocesses per test where practical — the port-forward helper (`portforward.go`) is still useful for genuinely external-only access patterns and for local developer use.
- Structure the suite so `go vet`/`golangci-lint` (or whatever the repo eventually settles on for Go) can run as part of spec 018's fast validation once this code exists.

## Testing / acceptance criteria

- `go test ./tests/e2e/... -args --context=<some-context>` fails immediately and clearly if no context/environment is supplied — confirms Requirement 4.
- Running the suite against an already-healthy cluster completes the readiness checks immediately, without waiting out a full poll timeout — confirms Requirement 6.
- Running only `--label-filter=postgres` executes exactly the Postgres checks and none of the others — confirms Requirement 11.
- The Postgres and Grafana checks each fail meaningfully (not just a generic timeout) when the corresponding service is deliberately broken (e.g., a wrong credential, a stopped pod) — confirms Requirements 7–8 test actual usability, not just presence.
- The exact same compiled test binary/suite, given a `kind` `Environment` vs. an `aws` `Environment`, produces the same pass/fail semantics for the same underlying service state — confirms Requirement 3's abstraction actually holds, not just that it compiles.
