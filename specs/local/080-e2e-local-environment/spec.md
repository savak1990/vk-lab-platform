---
id: "LOCAL-080"
title: "framework.LocalEnvironment; make test on local"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "A second implementation of an interface designed for it, plus one Go refactor to move the HTTP client behind that interface"
effort_estimate: "One session (3–4 h)"
estimate_confidence: "high"
depends_on: ["LOCAL-040", "LOCAL-050", "LOCAL-070"]
blocked_by: []
supersedes: ["spec 024 Req 4"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-080 — `framework.LocalEnvironment`; `make test` on local

## 1. Outcome and rationale

`PROVIDER=local make test` runs the existing Ginkgo suite unchanged in its
assertions against the developer-owned local cluster and passes. Constitution §11 requires
one test suite reused across targets rather than per-environment scripts;
the `Environment` interface was written for exactly this second
implementation.

## 2. Scope and non-goals

In scope:
- `framework.LocalEnvironment` implementing `Environment`: in
  `BeforeSuite` it opens an SPDY port-forward to the Envoy Service (found
  by the `gateway.envoyproxy.io/owning-gateway-name=envoy` label) on a
  free local port, exactly as `PostgresDSN` does for Postgres, and closes
  it in `AfterSuite`. `ServiceURL(route)` returns
  `http://<hostname>:<forwardPort>` where `<hostname>` is read from the
  HTTPRoute as today. `PostgresDSN` reuses the existing code unchanged.
- Move HTTP client construction behind the interface
  (`Environment.HTTPClient()`), so the local implementation returns a
  client whose `DialContext` sends every connection to
  `127.0.0.1:<forwardPort>` while the request keeps the route hostname as
  `Host`. The AWS implementation returns today's client.
- `suite_test.go`: select the environment by a `--provider` flag (set from
  `PROVIDER` by the Makefile); default `aws` keeps current behaviour.
- `Makefile` `test-kubeconfig` local branch: no-op (the developer's
  context, guarded by LOCAL-010's context check); `test` passes
  `--context=$(shell kubectl config current-context) --provider=local`.
  No test IAM role.
- `shared/rbac/e2e-test-readonly.yaml`: if the suite runs as the developer's
  cluster-admin context, no change; document that the local run does not
  exercise the read-only test identity.

Not in scope:
- New assertions. The suite is the same three files.
- Civo (`CIVO-130`).

## 3. Current state / evidence

- `tests/e2e/framework/environment.go:20-31` interface; `:62-75`
  `ServiceURL` reads `HTTPRoute.spec.hostnames[0]`; `:78-115`
  `PostgresDSN` port-forwards to the `-rw` pod.
- `tests/e2e/framework/config.go:26-33` flags (`--context` required,
  `--kubeconfig`, `--insecure-skip-tls-verify`); `:46` `HTTPClient()` on
  `Config`, used by `argocd_test.go:14` and `grafana_test.go:17`.
- `tests/e2e/suite_test.go:38` `NewAWSEnvironment` unconditional.
- `Makefile:204-226` `test-kubeconfig` (aws role, civo `exit 1`), `test`
  with `--context=$(PROJECT_NAME)-eks-test`.
- `framework/endpoints.go:25` and `environment.go:78-115` already contain
  the dynamic-client lookup and SPDY port-forward code the Envoy forward
  reuses.
- Assertions: Argo `/healthz`; Grafana `/api/health` + authenticated
  `/api/dashboards/home` reading `grafana-admin-credentials`; CNPG
  operator ready, `-rw` Service and `-app` Secret exist, `SELECT 1`,
  `CREATE TABLE` DDL.

## 4. Design and contracts

`LocalEnvironment.HTTPClient()`:

```go
&http.Client{Transport: &http.Transport{
    DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
        return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort("127.0.0.1", port))
    },
}}
```

Requests are built from `ServiceURL` (`http://argo.localhost:<port>/...`),
so `Host`/`:authority` carries the hostname and Envoy matches the route;
the dialer ignores the address. No `/etc/hosts` dependency, no
`InsecureSkipVerify` (plain HTTP), no dependency on `make local-forward`
being open — the suite owns its forward.

The `postgres` label tests need no change: the `-app` Secret is the one
`argo-up` created, with the same keys ESO produces on aws.

## 5. Files/components affected

`tests/e2e/framework/environment.go`, `config.go`, new `local.go`;
`tests/e2e/suite_test.go`; `tests/e2e/argocd_test.go`,
`grafana_test.go` (call sites of `HTTPClient()`); `Makefile`.

## 6. Implementation steps

1. Interface change and AWS client move; `go build ./...`; `go vet`.
2. `LocalEnvironment` and flag wiring.
3. Makefile branches.
4. `PROVIDER=local make test` on a running local platform: all three
   labels pass.
5. `PROVIDER=aws make -n test` output unchanged except no new flags with
   non-default values.

## 7. Dependencies and blockers

LOCAL-040 (Postgres), LOCAL-050 (routes), LOCAL-070 (Grafana).

## 8. Acceptance criteria

- `PROVIDER=local make test` passes with `--ginkgo.label-filter` unset.
- `PROVIDER=aws make test` compiles and the AWS path is behaviourally
  unchanged (same client, same flags).
- No new dependency in `go.mod`.

## 9. Validation

`go vet ./tests/...`; one local `make test` run (~2 min after `up`).

## 10. AWS regression protection

The AWS client is the same object moved behind the interface; `make -n`
diff and a compile are sufficient. An AWS `make test` run is not required
for this spec.

## 11. Rollout and rollback/recovery

Revert.

## 12. Risks and unresolved questions

- The suite runs as the developer's cluster-admin context, not a read-only identity. It
  proves the platform, not the RBAC contract; the AWS run still does.

## 13. Definition of done

- [ ] `LocalEnvironment` and flag wiring landed; Makefile branches
- [ ] Local `make test` green; AWS compile clean
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-040/050/070).
- 2026-09-11 — replanned: the suite opens its own Envoy port-forward; no fixed host port.
