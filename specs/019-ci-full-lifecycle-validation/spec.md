# 018 — CI Full Lifecycle Validation

**Complexity:** High
**Risk:** Medium–High — a manually-triggered create→destroy→recreate→destroy run against CI's own AWS environment; the main risk is leaked or orphaned CI resources, not damage to the personal lab (isolation is this spec's core requirement).
**Estimated cost:** ~2–3 days · AWS runtime cost: CI's own persistent/disposable stacks incur real cost while a run is active; budget for the stale-resource cleanup job from day one.
**Recommended model:** Opus for the run orchestration and postcondition checklist (the same reasoning burden as spec 014, now run unattended); Sonnet is fine for the scheduled cleanup job.
**Depends on:** 001-bootstrap (state/tagging conventions, and — since ADR 0007 — the one account-level GitHub OIDC provider this spec's CI role trusts), 002-persistent-foundation (delegated-subdomain pattern to replicate, one level down, for CI's own zone), 013-lifecycle (the exact `make up`/`make down` sequence this spec runs), 014-github-actions-lifecycle (this spec's CI-scoped role follows the same per-consumer role-scoping pattern as 015's personal-lab role — both trust spec 001's provider, neither creates its own), 016-atlantis-terraform-automation (this spec's CI-scoped IAM role follows the same per-stack scoping convention), 021-e2e-test-framework (the Go/Ginkgo suite this spec runs instead of ad hoc verification scripts)
**Lifecycle class(es) touched:** Bootstrap (CI's own OIDC trust), Persistent/Disposable (CI-specific `ci/persistent` and `ci/disposable` state, separate from the personal lab)

## Scope

Implements a manually-triggered `platform-integration.yml` workflow that runs the full create→verify→write→destroy→verify-persistence→recreate→verify-recovery→destroy→verify-no-leaks sequence from spec 014, against CI's own isolated state — plus a scheduled safety-net cleanup job (ADR 0007):

- `.github/workflows/platform-integration.yml` — `workflow_dispatch`-triggered (or triggered on a trusted-context push to `main` touching `terraform/**`/`gitops/**`), running spec 014's exact sequence against `terraform/live/ci/{persistent,disposable}` state, verified using spec 022's Go/Ginkgo E2E suite. A `mode` input selects between two runs of the same workflow:
  - `mode=routine` (the default): apply → E2E → idempotency check (a second `terraform plan` shows no diff) → destroy.
  - `mode=resilience`: apply → E2E → destroy → apply → E2E → destroy — the full recreate-after-destroy proof. Run on a schedule (e.g. nightly) or manually, never as part of a routine PR-triggered run, since it costs roughly twice as much and mainly proves teardown/recreation behavior that doesn't change with every Terraform edit.
- CI's own delegated DNS subdomain, `ci.lab.<root-domain>`, and its own ACM certificate covering `ci.lab.<root-domain>`/`*.ci.lab.<root-domain>` — the same Terraform pattern as the personal lab's `lab.<root-domain>` zone/certificate from spec 002, one level down, so this workflow can verify HTTPS without touching the personal lab's zone.
- `.github/workflows/cleanup-stale-ci.yml` — a scheduled (e.g., daily) job that identifies and removes orphaned CI resources left by a cancelled run, a runner crash, or a failed cleanup, using the standard tags, not name patterns.

CI's persistent and disposable layers are both single, shared environments — one `ci/persistent`, one `ci/disposable`, not one per PR. Runs are serialized (Requirement 7); this keeps the design simple and matches the actual trigger frequency of a maintainer-gated test, without the added machinery per-PR environments would need.

Excludes: the fast, lint-only PR checks (017); the kind-based GitOps integration test (022 — cheaper, AWS-free, runs on every relevant PR rather than being maintainer-gated); Atlantis's PR-triggered plan/apply on ordinary Terraform changes (016 — this spec runs the heavier, full-environment test, not routine plan/apply, and Atlantis holds no role for this spec's `ci/disposable` state); anything touching the personal lab's state, zone, or certificate. Also excludes the `local` target entirely — this spec's full lifecycle sequence is `aws`-target-only (spec 014 is what it runs, and spec 014 is `aws`-only).

## Requirements

1. This workflow MUST run the exact sequence from spec 014 (constitution §11, §12), against CI's own state, verified using spec 022's Go/Ginkgo E2E suite — not a reimplementation of that sequence or a parallel bash-based verification script.
2. CI infrastructure MUST be isolated from the personal lab environment (constitution §11). It MUST use separate state (`terraform/live/ci/persistent/`, `terraform/live/ci/disposable/`) and its own IAM role, distinct from spec 015's personal-lab role and spec 017's Atlantis roles. All three roles trust the one OIDC provider spec 001 creates (constitution §5) — this workflow can never touch personal data or resources.
3. Every disposable resource this workflow creates MUST carry the platform's standard tags (constitution §16) plus `Ephemeral=true`, so the scheduled cleanup job (Requirement 8) can find and remove anything left behind.
4. CI's shared persistent layer MUST have its own delegated DNS subdomain, `ci.lab.<root-domain>`, and its own wildcard ACM certificate covering `ci.lab.<root-domain>`/`*.ci.lab.<root-domain>` (mirroring spec 002's pattern one level down) for HTTPS verification — it MUST NOT reuse or modify the personal lab's `lab.<root-domain>` zone or certificate.
5. Untrusted/fork pull requests MUST NOT trigger this workflow or gain access to its credentials (constitution §11) — restrict triggering to `workflow_dispatch` by a maintainer, or to pushes on the main repository.
6. A failed run MUST still attempt cleanup of its disposable CI infrastructure (constitution's platform invariants) — the cleanup step MUST run even on failure (e.g., `if: always()`).
7. GitHub Actions concurrency controls and Terraform state locking MUST prevent two concurrent runs from mutating the same CI state (architecture.md §32) — one `concurrency:` group covers this workflow, with `cancel-in-progress: false`, so overlapping triggers queue rather than race against the same shared `ci/disposable` environment.
8. A scheduled stale-resource cleanup job MUST exist as a safety net (architecture.md §31) — it MUST identify candidates using the standard platform tags plus `Ephemeral=true` (Requirement 3), not name patterns or manual account scanning, so it never risks touching an untagged or unrelated resource.
9. The recreate-after-destroy resilience proof MUST run as `mode=resilience` on this same workflow (Requirement 1), not as part of a routine `mode=routine` PR-triggered run.

## Implementation hints

- Create only this spec's own role, trusting the single OIDC provider spec 001 already created (do not create a second provider) — scope its trust policy and IAM permissions to `terraform/live/ci/*` state paths only, mirroring spec 015's personal-lab role pattern at the role level.
- Use a single GitHub Actions `concurrency:` group (e.g., `ci-full-lifecycle`) with `cancel-in-progress: false` covering both `mode=routine` and `mode=resilience` runs of this workflow, since they share the same `ci/disposable` state.
- CI's delegated subdomain and certificate (Requirement 4) live in `terraform/live/ci/persistent/`, reusing the exact same Terraform modules as the personal lab's zone/certificate from spec 002 — same mechanism, one level down (`ci.lab.<root-domain>` instead of `lab.<root-domain>`).
- Implement `mode` as a `workflow_dispatch` input (default `routine`) with the resilience branch simply repeating the apply→E2E→destroy steps twice and skipping the idempotency-check step — its own destroy→recreate cycle already proves more than a no-diff plan would.
- The scheduled cleanup job can reuse the same postcondition-checking logic built in spec 014, scoped to the CI account/tag namespace, run on a cron trigger independent of any specific workflow run.

## Testing / acceptance criteria

- A manually-triggered `mode=routine` run completes the entire CREATE→...→VERIFY NO LEAKS sequence against `terraform/live/ci/` state successfully, using spec 022's E2E suite for verification, including HTTPS verification against CI's own delegated subdomain.
- A manually-triggered `mode=resilience` run completes its create→verify→destroy→create→verify→destroy cycle successfully, and is confirmed to not run as part of a routine PR-triggered `mode=routine` run.
- Two runs triggered concurrently (regardless of mode) are serialized by the concurrency group rather than both proceeding against the same state.
- A deliberately-failed run (inject a failure partway through) still results in disposable CI resources being cleaned up — confirm via the postcondition checklist.
- A fork-originated pull request cannot trigger this workflow or obtain its credentials — confirm by inspecting the workflow's trigger configuration and a fork PR's run permissions.
- The scheduled cleanup job identifies and removes a deliberately-orphaned, tagged CI resource on its next scheduled run, using tag-based identification only.
- CI's role cannot assume or touch anything scoped to the personal lab's state paths or DNS zone (spec 015), or Atlantis's per-stack roles (spec 017), and vice versa — and confirm it shares spec 001's single OIDC provider rather than a second one existing in the account.
