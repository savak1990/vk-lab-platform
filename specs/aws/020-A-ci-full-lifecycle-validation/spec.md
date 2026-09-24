---
id: "AWS-020"
status: "IN_PROGRESS"
updated: "2026-09-19"
---
# 020 — CI Full Lifecycle Validation

**Complexity:** High
**Risk:** Medium–High — a manually-triggered create→destroy→recreate→destroy run against CI's own AWS environment; the main risk is leaked or orphaned CI resources, not damage to the personal lab (isolation is this spec's core requirement).
**Estimated cost:** ~2–3 days · AWS runtime cost: CI's own persistent/disposable stacks incur real cost while a run is active; budget for the stale-resource cleanup job from day one.
**Recommended model:** Opus for the run orchestration and postcondition checklist (the same reasoning burden as spec 014, now run unattended); Sonnet is fine for the scheduled cleanup job.
**Depends on:** 001-bootstrap (state/tagging conventions), 015-github-oidc-bootstrap (the one account-level GitHub OIDC provider this spec's CI role trusts), 002-persistent-foundation (delegated-subdomain pattern to replicate, one level down, for CI's own zone), 013-lifecycle (the exact `make up`/`make down` sequence this spec runs), 014-github-actions-lifecycle (this spec's CI-scoped role follows the same per-consumer role-scoping pattern as 017's personal-lab role — both trust spec 015's provider, neither creates its own), 018-atlantis-terraform-automation (this spec's CI-scoped IAM role follows the same per-stack scoping convention), 023-e2e-test-framework (the Go/Ginkgo suite this spec runs instead of ad hoc verification scripts)
**Lifecycle class(es) touched:** Bootstrap (CI's own OIDC trust), Persistent/Disposable (CI-specific `ci/persistent` and `ci/cluster` state, separate from the personal lab)

## Scope

Implements a manually-triggered `platform-integration.yml` workflow that runs the full create→verify→write→destroy→verify-persistence→recreate→verify-recovery→destroy→verify-no-leaks sequence from spec 014, against CI's own isolated state — plus a scheduled safety-net cleanup job (ADR 0007):

- `.github/workflows/platform-integration.yml` — `workflow_dispatch`-triggered (or triggered on a trusted-context push to `main` touching `terraform/**`/`gitops/**`), running spec 014's exact sequence against `terraform/live/ci/{persistent,disposable}` state, verified using spec 023's Go/Ginkgo E2E suite. The workflow runs one mode: apply → E2E → idempotency check (a second `terraform plan` shows no diff) → destroy. A second `mode=resilience` run — apply → E2E → destroy → apply → E2E → destroy — was specified here originally and **withdrawn on 2026-09-24** under constitution §13: it costs roughly twice as much per run and mainly proves teardown and recreation behaviour that does not change with every Terraform edit. Constitution §4 and §12 still require that destroy and recreate behaviour be tested; CNPG data survival across a `make down`/`make up` cycle (AWS-007-1, CIVO-120, HETZ-120) and the merge-gate lifecycle leg's `up` → `test` → `down` carry that obligation.
- CI's own delegated DNS subdomain, `ci.lab.<root-domain>`, and its own ACM certificate covering `ci.lab.<root-domain>`/`*.ci.lab.<root-domain>` — the same Terraform pattern as the personal lab's `lab.<root-domain>` zone/certificate from spec 002, one level down, so this workflow can verify HTTPS without touching the personal lab's zone.
- `.github/workflows/cleanup-stale-ci.yml` — a scheduled (e.g., daily) job that identifies and removes orphaned CI resources left by a cancelled run, a runner crash, or a failed cleanup, using the standard tags, not name patterns.

CI's persistent and disposable layers are both single, shared environments — one `ci/persistent`, one `ci/cluster`, not one per PR. Runs are serialized (Requirement 7); this keeps the design simple and matches the actual trigger frequency of a maintainer-gated test, without the added machinery per-PR environments would need.

Excludes: the fast, lint-only PR checks (018); the kind-based GitOps integration test (023 — cheaper, AWS-free, runs on every relevant PR rather than being maintainer-gated); Atlantis's PR-triggered plan/apply on ordinary Terraform changes (017 — this spec runs the heavier, full-environment test, not routine plan/apply, and Atlantis holds no role for this spec's `ci/cluster` state); anything touching the personal lab's state, zone, or certificate. Also excludes the `local` target entirely — this spec's full lifecycle sequence is `aws`-target-only (spec 014 is what it runs, and spec 014 is `aws`-only).

## Requirements

1. This workflow MUST run the exact sequence from spec 014 (constitution §11, §12), against CI's own state, verified using spec 023's Go/Ginkgo E2E suite — not a reimplementation of that sequence or a parallel bash-based verification script.
2. CI infrastructure MUST be isolated from the personal lab environment (constitution §11). It MUST use separate state (`terraform/live/ci/persistent/`, `terraform/live/ci/cluster/`) and its own IAM role, distinct from spec 016's personal-lab role and spec 018's Atlantis roles. All three roles trust the one OIDC provider spec 015 creates (constitution §5) — this workflow can never touch personal data or resources.
3. Every disposable resource this workflow creates MUST carry the platform's standard tags (constitution §16) plus `Ephemeral=true`, so the scheduled cleanup job (Requirement 8) can find and remove anything left behind.
4. CI's shared persistent layer MUST have its own delegated DNS subdomain, `ci.lab.<root-domain>`, and its own wildcard ACM certificate covering `ci.lab.<root-domain>`/`*.ci.lab.<root-domain>` (mirroring spec 002's pattern one level down) for HTTPS verification — it MUST NOT reuse or modify the personal lab's `lab.<root-domain>` zone or certificate.
5. Untrusted/fork pull requests MUST NOT trigger this workflow or gain access to its credentials (constitution §11) — restrict triggering to `workflow_dispatch` by a maintainer, or to pushes on the main repository. **Amended 2026-09-19 (ADR 0035):** the trigger is now a `ci:lifecycle` label applied to a pull request. Labelling requires write access, so the trust property is unchanged, and every credentialed job additionally carries an explicit same-repository test. See `specs/shared/035-D-pr-lifecycle-gate/`.
6. A failed run MUST still attempt cleanup of its disposable CI infrastructure (constitution's platform invariants) — the cleanup step MUST run even on failure (e.g., `if: always()`).
7. GitHub Actions concurrency controls and Terraform state locking MUST prevent two concurrent runs from mutating the same CI state (architecture.md §32) — one `concurrency:` group covers this workflow, with `cancel-in-progress: false`, so overlapping triggers queue rather than race against the same shared `ci/cluster` environment.
8. A scheduled stale-resource cleanup job MUST exist as a safety net (architecture.md §31) — it MUST identify candidates using the standard platform tags plus `Ephemeral=true` (Requirement 3), not name patterns or manual account scanning, so it never risks touching an untagged or unrelated resource.

## Status of this spec as implemented

Two workflows implement parts of this spec, both deviating from it under
constitution §13:

- ADR 0026 built `lifecycle-test.yml` against `PROJECT_NAME`/`SUBDOMAIN`
  isolation instead of Requirement 2's `terraform/live/ci/` tree.
- ADR 0035 turned that workflow into the merge gate for `main` and extended it
  to run both providers at once. It amends Requirement 5 as noted above, and
  satisfies Requirements 6 and 7 for both providers.

Still outstanding, which is why this spec is not DONE:

- Requirement 3, the `Ephemeral=true` tag — no resource carries it.
- Requirement 8, the scheduled stale-resource reaper — does not exist.
  Recovery from a failed teardown is a documented `lab.yml` dispatch instead.
- Requirement 4's own `ci.lab.<root-domain>` zone — each CI project gets its
  own subdomain zone under ADR 0026's isolation model instead.

## Implementation hints

- Create only this spec's own role, trusting the single OIDC provider spec 015 already created (do not create a second provider) — scope its trust policy and IAM permissions to `terraform/live/ci/*` state paths only, mirroring spec 016's personal-lab role pattern at the role level.
- Use a single GitHub Actions `concurrency:` group (e.g., `ci-full-lifecycle`) with `cancel-in-progress: false`, since every run of this workflow shares the same `ci/cluster` state.
- CI's delegated subdomain and certificate (Requirement 4) live in `terraform/live/ci/persistent/`, reusing the exact same Terraform modules as the personal lab's zone/certificate from spec 002 — same mechanism, one level down (`ci.lab.<root-domain>` instead of `lab.<root-domain>`).
- Implement `mode` as a `workflow_dispatch` input (default `routine`) with the resilience branch simply repeating the apply→E2E→destroy steps twice and skipping the idempotency-check step — its own destroy→recreate cycle already proves more than a no-diff plan would.
- The scheduled cleanup job can reuse the same postcondition-checking logic built in spec 014, scoped to the CI account/tag namespace, run on a cron trigger independent of any specific workflow run.

## Testing / acceptance criteria

- A manually-triggered `mode=routine` run completes the entire CREATE→...→VERIFY NO LEAKS sequence against `terraform/live/ci/` state successfully, using spec 023's E2E suite for verification, including HTTPS verification against CI's own delegated subdomain.
- Two runs triggered concurrently (regardless of mode) are serialized by the concurrency group rather than both proceeding against the same state.
- A deliberately-failed run (inject a failure partway through) still results in disposable CI resources being cleaned up — confirm via the postcondition checklist.
- A fork-originated pull request cannot trigger this workflow or obtain its credentials — confirm by inspecting the workflow's trigger configuration and a fork PR's run permissions.
- The scheduled cleanup job identifies and removes a deliberately-orphaned, tagged CI resource on its next scheduled run, using tag-based identification only.
- CI's role cannot assume or touch anything scoped to the personal lab's state paths or DNS zone (spec 016), or Atlantis's per-stack roles (spec 018), and vice versa — and confirm it shares spec 015's single OIDC provider rather than a second one existing in the account.
