# 019 — CI Full Lifecycle Validation

**Complexity:** High
**Risk:** Medium–High — a manually-triggered create→destroy→recreate→destroy run against CI's own AWS environment; the main risk is leaked or orphaned CI resources, not damage to the personal lab (isolation is this spec's core requirement).
**Estimated cost:** ~2–3 days · AWS runtime cost: CI's own persistent/disposable stacks incur real cost while a run is active; budget for the stale-resource cleanup job from day one.
**Recommended model:** Opus for the run orchestration and postcondition checklist (the same reasoning burden as spec 014, now run unattended); Sonnet is fine for the scheduled cleanup job.
**Depends on:** 001-bootstrap (state/tagging conventions), 002-persistent-foundation (delegated-subdomain pattern to replicate for CI's own zone), 014-lifecycle (the exact `make up`/`make down` sequence this spec runs), 015-github-actions-lifecycle (this spec's CI-scoped OIDC role mirrors 015's OIDC provider/role pattern, not spec 001 — 001 no longer creates OIDC), 017-atlantis-terraform-automation (this spec's CI-scoped IAM role follows the same per-stack scoping convention)
**Lifecycle class(es) touched:** Bootstrap (CI's own OIDC trust), Persistent/Disposable (CI-specific `ci/persistent` and `ci/disposable` state, separate from the personal lab)

## Scope

Implements a manually-triggered `platform-integration.yml` workflow that runs the full create→verify→write→destroy→verify-persistence→recreate→verify-recovery→destroy→verify-no-leaks sequence from spec 014, against CI's own isolated state — plus a scheduled safety-net cleanup job:

- `.github/workflows/platform-integration.yml` — `workflow_dispatch`-triggered (or triggered on a trusted-context push to `main` touching `terraform/**`/`gitops/**`), running spec 014's exact sequence against `terraform/live/ci/{persistent,disposable}` state.
- CI's own delegated DNS subdomain (e.g., `ci.lab.<root-domain>`), following the same Terraform pattern as the personal lab's `lab.<root-domain>` zone/certificate from spec 002, so this workflow can verify HTTPS without touching the personal lab's zone.
- `.github/workflows/cleanup-stale-ci.yml` — a scheduled (e.g., daily) job that identifies and removes orphaned CI resources left by a cancelled run, a runner crash, or a failed cleanup.

Excludes: the fast, lint-only PR checks (018); Atlantis's PR-triggered plan/apply on ordinary Terraform changes (017 — this spec runs the heavier, full-environment test, not routine plan/apply); anything touching the personal lab's state, zone, or certificate.

## Requirements

1. This workflow MUST run the exact sequence from spec 014 (constitution §11, §12), against CI's own state — not a reimplementation of that sequence.
2. CI infrastructure MUST be isolated from the personal lab environment (constitution §11) — separate `terraform/live/ci/{persistent,disposable}` state, and a distinct OIDC role from both the personal lab's role (spec 015) and Atlantis's per-stack roles (spec 017), so this workflow can never touch personal data or resources.
3. CI's isolated environment MUST have its own delegated DNS subdomain (e.g., `ci.lab.<root-domain>`) for HTTPS verification — it MUST NOT reuse or modify the personal lab's `lab.<root-domain>` zone or certificate.
4. Untrusted/fork pull requests MUST NOT trigger this workflow or gain access to its credentials (constitution §11) — restrict triggering to `workflow_dispatch` by a maintainer, or to pushes on the main repository.
5. A failed run MUST still attempt cleanup of its disposable CI infrastructure (constitution's platform invariants) — the cleanup step MUST run even on failure (e.g., `if: always()`).
6. GitHub concurrency controls and Terraform state locking MUST prevent two concurrent runs from mutating the same CI state (architecture.md §32).
7. A scheduled stale-resource cleanup job MUST exist as a safety net (architecture.md §31) — it MUST identify candidates using the standard platform tags (constitution §16: `Project=vk-lab-platform`, `Scope=platform`, `Lifecycle=disposable`), not name patterns or manual account scanning, so it never risks touching an untagged or unrelated resource.

## Implementation hints

- Mirror the OIDC provider/role pattern spec 015 establishes (the platform's first GitHub-OIDC consumer), but scoped to `terraform/live/ci/*` state paths only — this is the actual isolation mechanism, not just a naming convention.
- Use a GitHub Actions `concurrency:` group keyed on the CI state path (e.g., `ci-disposable-lifecycle`) so overlapping runs queue instead of racing.
- CI's own delegated subdomain (Requirement 3) can be created as part of `terraform/live/ci/persistent/`, reusing the exact same Terraform module as the personal lab's zone/certificate from spec 002 — same mechanism, different zone, so the two environments' DNS never overlaps.
- The scheduled cleanup job can reuse the same postcondition-checking logic built in spec 014, scoped to the CI account/tag namespace, run on a cron trigger independent of any specific workflow run.

## Testing / acceptance criteria

- A manually-triggered run completes the entire CREATE→...→VERIFY NO LEAKS sequence against `terraform/live/ci/` state successfully, including HTTPS verification against CI's own delegated subdomain.
- A deliberately-failed run (inject a failure partway through) still results in disposable CI resources being cleaned up — confirm via the postcondition checklist.
- A fork-originated pull request cannot trigger this workflow or obtain its credentials — confirm by inspecting the workflow's trigger configuration and a fork PR's run permissions.
- The scheduled cleanup job identifies and removes a deliberately-orphaned tagged EC2 instance on its next scheduled run, using tag-based identification only.
- Two runs triggered concurrently are serialized by the concurrency group rather than both proceeding against the same state.
- CI's OIDC role cannot assume or touch anything scoped to the personal lab's state paths or DNS zone (spec 015), or Atlantis's per-stack roles (spec 017), and vice versa.
