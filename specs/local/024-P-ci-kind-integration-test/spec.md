---
id: "LOCAL-024"
status: "READY"
updated: "2026-09-17"
---
# 023 — CI Kind Integration Test

**Complexity:** Medium
**Risk:** Medium — no AWS resources involved, but it runs PR-controlled workloads (GitOps content) on GitHub-hosted runner compute, so it needs the same fork-safety posture as the AWS-touching workflows.
**Estimated cost:** ~1–1.5 days · AWS runtime cost: none — kind runs entirely on the GitHub Actions runner (or a laptop).
**Recommended model:** Sonnet.
**Depends on:** 022-local-dev-mode (the `PROVIDER=local` bring-up this spec reuses), 023-e2e-test-framework (the suite this spec runs), 019-ci-fast-validation (shares the trusted-context/fork-safety posture pattern), ADR 0038.
**Lifecycle class(es) touched:** none — entirely outside the `aws`-target lifecycle model, same as spec 022's `local` target it builds on.

## Scope

Adds the cheap, AWS-free CI path spec 022 anticipated and deliberately left out of its own scope: a CI job that runs `PROVIDER=local make up` against the exact commit under test, lets Argo CD reconcile the platform on kind, runs spec 023's Go/Ginkgo E2E suite against it, and tears the cluster down.

- No new Makefile lifecycle targets. ADR 0038 put the `local` target on the shared command surface, so `PROVIDER=local make up` / `make test` / `make down` already exist. `make test` and `make test-<service>` also already exist (spec 023's Ginkgo labels); this spec only gives them a `local` arm.
- A `kind-integration` job inside `.github/workflows/lifecycle-test.yml` — a thin wrapper calling the same commands a developer runs, with the root Application's `targetRevision` set to the PR's exact commit SHA. It lives beside the validate-* jobs rather than in a workflow of its own, the same way SHARED-019's separate `validate.yml` was folded in (ADR 0035).

Excludes: `minikube`, which ADR 0038 dropped from spec 022 entirely — kind is the only local tool the platform supports; any AWS-specific integration (NLB, Route 53, ACM, EBS/EFS CSI, Pod Identity, AWS Secrets Manager) — those cannot be faithfully tested here and remain spec 020's job; installing Postgres/Kafka/Grafana directly in test setup — Argo CD owns that (constitution §6), exactly as it does for the `aws` target.

## Requirements

1. This job MUST reuse spec 022's `PROVIDER=local make up` unchanged — it MUST NOT introduce a second, divergent way to create the cluster or install Argo CD on kind.
2. The CI job MUST call the same `make` targets a developer runs rather than re-implementing any of their logic in workflow YAML — it stays a thin wrapper (mirrors spec 016's "thin wrapper" requirement for `lab.yml`). `make test` MUST gain a `local` arm: `configure_test_kubeconfig` today returns 1 for any provider but `aws` and `civo`, so the suite cannot reach a kind cluster without one. A `make test-<service>` target MUST exist for each service that already has a Ginkgo label (spec 023) — do not add one ahead of the corresponding test file landing.
3. The root Argo Application applied during this test MUST point its `targetRevision` at the pull request's exact commit SHA, not `main` — this is what lets the test validate the PR's actual GitOps content rather than whatever is already on `main`.
4. Tests MUST NOT install Postgres, Kafka, Grafana, or any other platform service themselves. Argo CD MUST be the sole installer, reconciling from the GitOps bootstrap exactly as it does for the `aws` target.
5. This spec MUST maintain an explicit, current list of AWS-specific integrations it cannot faithfully test — at minimum: NLB, Route 53, ACM, EBS/EFS CSI, Pod Identity, AWS Secrets Manager integration. Any test that would require one of these MUST be skipped here (via spec 023's Ginkgo labels or environment-specific test selection) and left to spec 020 instead — never faked or approximated with a kind-only substitute that could mask a real AWS-side regression.
6. This job MUST run only in a trusted GitHub context (the same posture as spec 020's full-lifecycle test, constitution §11/architecture.md §30) — even though it touches no AWS resources, it still executes PR-controlled workloads on GitHub-hosted runner compute, which is exactly the abuse vector (e.g. cryptomining via a malicious Kubernetes workload) those existing restrictions exist to prevent. It MUST NOT run via `pull_request_target` on untrusted PR code.
7. Because this job holds no persistent cloud state, its GitHub Actions `concurrency:` group MUST use `cancel-in-progress: true` (unlike the lifecycle jobs' `cancel-in-progress: false`, which exists so a cancellation never kills a teardown mid-flight) — a superseded run can simply be cancelled and restarted with the newer commit, since nothing about it is expensive to interrupt or slow to recreate.
8. Fast validation (spec 019) MUST continue to cover `gitops/**` changes via `helm template`/schema rendering as it already does (spec 022 Requirement 16) — this spec's kind-based test is a deeper, slower check layered on top of that, not a replacement for it.

## Implementation hints

- `make test` should accept an optional service filter (e.g. `make test SERVICE=postgres` invoking `make test-postgres`), or `make test-postgres` etc. can simply be thin wrappers around `ginkgo --label-filter=postgres ./tests/e2e/...` — either is fine as long as the mapping from Makefile target to Ginkgo label is obvious and documented in the Makefile itself.
- Pointing the root Application's `targetRevision` at the PR's commit SHA can reuse whatever mechanism spec 022 Requirement 15 chose for syncing from a local working directory, or simply set `targetRevision` to `${{ github.event.pull_request.head.sha }}` if the CI cluster syncs from the GitHub repo (rather than a local checkout) for this particular workflow — pick whichever is simpler given spec 022's final mechanism, and document the choice here once made.
- A GitHub Actions matrix or simple sequential `make test-<service>` calls both work for running services in parallel/isolation (spec 023 Requirement 10/11); start with whichever is simpler to wire up and revisit if CI time becomes a problem.
- Keep the job's only real logic in the trusted-context gate (Requirement 6) — everything else is `make up && make test && make down` under `PROVIDER=local`. Teardown can be a step with `if: always()` rather than the separate job the cloud lifecycle workflows need: a kind cluster dies with the runner, so there is nothing to leak.
- Two landmines in `lifecycle-test.yml`: `pr-gate` hardcodes the number of validation results it expects, so that literal must move in the same change; and `.github/(workflows|actions)/` is on the `infra` path list, so the pull request adding this job is itself infra-classified.
- `.github/actions/setup-lab-tools` installs neither kind nor, at `scope: test`, helm. Pin and checksum the kind install the way the civo CLI already is.

## Testing / acceptance criteria

- `PROVIDER=local make up && PROVIDER=local make test` run locally with no AWS credentials present succeeds end to end: cluster created, Argo CD installed, platform reconciled, E2E suite passes.
- A labeled PR that changes something under `gitops/**` runs the `kind-integration` job, which reaches the same healthy end state as the local run, tested against that PR's exact commit (not `main`) — confirmed by deliberately breaking something in the PR's `gitops/` content and observing the job fail on that specific break rather than on a timeout.
- A fork-originated, untrusted pull request does not trigger this workflow or gain access to any credential it might otherwise need — confirmed by inspecting the workflow's trigger/permissions configuration and observing a fork PR's run (or non-run).
- Pushing a second commit to an open PR cancels the first `kind-integration.yml` run in favor of the new one (Requirement 7) — confirmed by observing the workflow run history for that PR.
- Deliberately triggering a check this spec has flagged as AWS-only (Requirement 5, e.g. a Pod Identity assertion) is confirmed absent from this workflow's test selection — it only runs in spec 020.
