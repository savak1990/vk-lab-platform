# ADR 0007: CI/CD account bootstrap, fork configurability, and Go/Ginkgo E2E testing

> **Note (2026-08-28):** every spec number below predates a later renumber.
> The OIDC provider is now spec 015, not spec 001, and lives in
> `terraform/live/account/` applied by `make account-up`, not in the Bootstrap
> stack — see ADR 0021. The decision this ADR records (exactly one provider per
> account, per-consumer roles trusting it) is unchanged and still binding; only
> its location and owning spec moved. Body left as written, since an ADR records
> what was decided when.

## Status

Accepted

## Context

The platform's CI/CD design (specs 014–020) predates a broader set of
requirements: the repo must be fully forkable with zero code changes, must
support cheap kind-based GitOps testing alongside optional full-AWS testing,
must authenticate GitHub Actions to AWS without long-lived credentials, and
must run the same E2E assertions locally, in kind, and against real EKS.

Two problems in the existing design block that:

- The GitHub OIDC **provider** (`token.actions.githubusercontent.com`) is
  currently created by spec 015, framed as part of the personal lab's
  lab-up/lab-down workflows. AWS allows exactly one OIDC provider per
  provider URL per account — spec 019's text ("mirrors 014's OIDC
  provider/role pattern") is ambiguous about whether it creates a second
  provider, which would fail outright. The provider is inherently
  account-level, region-agnostic infra, not something owned by whichever
  spec happens to need a role first.
- Nothing addresses fork-owner configurability. Making the repo genuinely
  forkable without code changes requires a documented, minimal set of
  GitHub-side configuration values, separate from the mechanism this
  platform already uses for its own committed secrets.

Separately, there is no test framework of any kind on disk today, no
GitOps-layer CI test cheaper than a full EKS cluster, and spec 021 (local
dev mode) deliberately stopped short of CI integration, flagging it as "a
separate, explicitly scoped addition" — this ADR is that addition.

## Decision

### Account bootstrap and OIDC

The GitHub OIDC provider is created exactly once, as part of spec 001
(Bootstrap-lifecycle), never recreated or destroyed by `make up`/`make
down`/`make bootstrap-down`. It is account-level and region-agnostic: the
same provider is reused regardless of which AWS region a given stack
deploys into.

Individual **IAM roles** trusting that one provider remain owned by their
respective consumer specs, each scoped to only the state paths and actions
that consumer needs:

- Spec 014's personal-lab role — the "normal deploy" role, scoped to the
  personal lab's persistent/disposable state.
- Spec 018's CI role — the "privileged full-environment-test" role, scoped
  to `ci/*` state paths only.

This gives the deploy-role/privileged-test-role separation directly, without
inventing a third role: the split already existed by accident of which spec
needed a role for which purpose; this ADR just makes the provider/role
boundary explicit and correct.

Atlantis (spec 017) is unaffected — it never used OIDC and continues
authenticating via its own compute's instance/task role.

### Fork configurability

A forked repository needs exactly:

1. Account bootstrap run once against the fork owner's AWS account (creates
   the OIDC provider, KMS key, and whichever IAM roles that owner wants —
   personal-lab and/or CI).
2. `AWS_ROLE_ARN` set as a GitHub Environment/repository **variable**.
3. `AWS_REGION` set as a GitHub Environment/repository **variable**.

No source change. `AWS_ROLE_ARN`/`AWS_REGION` are configuration, not
credentials — safe as plain variables. `ROOT_DOMAIN` no longer needs a
separate GitHub secret (see "Alternatives considered" (c), superseded by
ADR 0023): CI decrypts the committed `secrets/root-domain.enc` KMS
ciphertext the same way a workstation run does, via
`scripts/secret-decrypt.sh` against the account's KMS key — one path, not
two.

### Change-aware CI gate

Spec 017 (Fast Validation) gains an always-running gate job that fans out to
path-filtered sub-jobs (terraform, gitops/helm, docs-only) and always
reports a result, so a documentation-only PR never leaves a path-filtered
required check permanently pending.

### Go/Ginkgo E2E framework and environment abstraction

A new spec (021) introduces a Ginkgo v2/Gomega-based E2E suite
(`tests/e2e/`), using `client-go` for Kubernetes access, `pgx` for Postgres,
and `net/http` for HTTP API checks. Bash remains for orchestration/bootstrap
only, never as the primary test framework. An `Environment` interface
abstracts *how* a test reaches a service (port-forward on kind vs. real
ingress/DSN on `aws`) so the same assertions run against both without
duplicating test logic; the framework takes an explicit Kubernetes context
so a run never accidentally targets an unrelated cluster.

### Kind-based CI GitOps integration test

A new spec (022) adds a cheap CI path that creates a kind cluster, installs
Argo CD via spec 021's plain-script local install, applies the repository's
normal GitOps bootstrap pointed at the PR's exact commit (not `main`), lets
Argo reconcile the platform, and runs spec 022's E2E suite against it. Tests
never install Postgres/Kafka/Grafana themselves — Argo CD owns installation,
exactly as it does for the `aws` target. The same `make kind-up`/`make
test`/`make kind-delete` targets work identically from a laptop and from the
GitHub Actions workflow that wraps them.

This test cannot faithfully exercise AWS-specific integrations
(NLB, Route 53, ACM, EBS/EFS CSI, Pod Identity, AWS Secrets Manager
integration) — those remain spec 019's job. It is restricted to
trusted-context PRs (the same fork-safety posture as spec 019), since it
still spends real GitHub-hosted runner compute even though it touches no
AWS resources.

### One shared, serialized CI environment

Spec 018's full-lifecycle validation runs against one shared `ci/persistent`
plus one shared `ci/disposable` environment — not one environment per PR.
Runs are serialized by a single GitHub Actions `concurrency:` group
(`cancel-in-progress: false`); a second trigger queues behind whatever run
is already in progress. Disposable resources are tagged `Ephemeral=true` so
the scheduled cleanup job can find anything left behind.

A per-PR ephemeral model (its own Terraform state key, its own
`pr-<N>.ci.lab.<root-domain>` record, `PR`/`Environment` tags, per-PR
concurrency groups so different PRs run in parallel) was drafted and then
rejected during review: full-environment tests already require a
trusted/maintainer trigger (constitution §11, architecture §30), so this
repository realistically runs one or two such tests at a time, not enough to
justify the added state/DNS/tag plumbing a genuinely parallel model needs.
One shared, serialized environment gets the same isolation from the personal
lab with far less to build and maintain. If trigger volume ever grows enough
that serialization becomes the bottleneck, revisit — see "Alternatives
considered" below.

The recreate-after-destroy resilience proof runs as a `mode=resilience`
input on the same `platform-integration.yml` workflow (default
`mode=routine`), rather than as a second workflow file — the two modes share
nearly every step, differing only in whether the destroy→recreate cycle
repeats and whether an idempotency plan-check runs. Run `mode=resilience` on
a schedule (e.g. nightly) or manually, never as part of a routine PR-triggered
run — it costs roughly twice as much and mainly proves teardown/recreation
behavior that doesn't change with every Terraform edit.

## Alternatives considered

**a. A second OIDC provider per consumer (014, 018 each creating their
own).** Rejected: AWS permits only one provider per URL per account: the
second creation would simply fail. There is exactly one provider; roles are
the actual per-consumer unit.

**b. Per-PR parallel ephemeral AWS CI environments** (its own Terraform
state key, DNS record, and tags per PR, so different PRs' full-lifecycle
tests can run concurrently). Drafted first, then rejected: at the trigger
frequency full-environment tests actually run (maintainer-gated, not every
PR), the added state/DNS/tag/concurrency-group plumbing this needs costs
more to build and maintain than the parallelism is worth — see "One shared,
serialized CI environment" above.

**b1. A second, separate workflow file for the recreate-after-destroy
resilience proof (`resilience-test.yml`).** Rejected: it would duplicate
nearly every step of `platform-integration.yml`. A `mode` input on the same
workflow file gets the same separation of "when this expensive proof runs"
without a near-duplicate file to keep in sync.

**c. `ROOT_DOMAIN` supplied to GitHub Actions by decrypting the committed
`secrets/root-domain.enc` in-workflow, instead of a separate GitHub secret.**
Originally rejected here on the premise that it would widen `lab-role`'s IAM
scope for no benefit. **Superseded by ADR 0023**: the SSM Parameter Store
migration already grants `lab-role` `kms:*` on `alias/lab-secrets` (to
decrypt SecureString parameters), so the premise no longer holds — the
`secrets.ROOT_DOMAIN` GitHub secret was removed and CI now decrypts
`secrets/root-domain.enc` directly, same as a workstation run.

**d. Duplicating service test logic per environment (one test file for kind,
another for `aws`) instead of an `Environment` abstraction.** Rejected: the
whole point of the kind-based CI test is to give confidence in the same
assertions that run against real EKS; duplicated test code drifts and
defeats that purpose.

**e. Running the kind-based integration test on every PR including
untrusted fork PRs.** Rejected: even though it touches no AWS resources, it
still spends real GitHub-hosted runner compute on PR-controlled code,
matching the same abuse concern (e.g. cryptomining via a malicious kind
workload) constitution §11/architecture §30 already gate the AWS tests on.
Trusted-context-only, consistent with spec 019.

## Consequences

- Spec 001 gains a `terraform/live/bootstrap/github-oidc/` unit (provider
  only); spec 015's "moved to spec 015" scope-amendment note is corrected —
  it now creates only its own role.
- Spec 018's OIDC-role dependency text is corrected to reuse spec 001's
  provider. Its own CI-persistent zone/certificate (one level down from
  spec 002's pattern) and `Ephemeral=true` tagging are new; the environment
  itself stays shared and serialized, and the resilience proof becomes a
  `mode` input on the same workflow rather than a second file.
- Spec 002's original scope note distinguishing a GitHub-secret path for
  `ROOT_DOMAIN` (CI) from the KMS-ciphertext path (workstation) no longer
  applies — superseded by ADR 0023, both paths now decrypt the same
  ciphertext.
- Spec 017 gains the always-green gate/change-detection requirement.
- Two new specs (021, 022) exist where previously there was a deliberate
  gap flagged by spec 021.
- Architecture.md and the constitution each gain a short Fork
  Configurability section and an Account Bootstrap/OIDC section recording
  the provider/role split as a binding rule, not just a Terraform detail.
- None of this changes the `aws`/`local` execution-target design from ADR
  0006 — the kind-based CI test (022) is a *consumer* of spec 021's local
  install path, not a change to it.
