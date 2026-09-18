---
id: "SHARED-035"
title: "Label-gated two-provider lifecycle check as the required status check on main"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow and GitHub configuration with a clear security checklist; the reasoning is in the ADR"
effort_estimate: "One session plus one labeled CI run per verification step"
estimate_confidence: "medium"
depends_on: ["SHARED-017", "CIVO-140", "AWS-020"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-19"
---

# SHARED-035 — PR lifecycle gate

## 1. Outcome and rationale

A pull request that changes infrastructure cannot merge into `main` until one
AWS cluster and one Civo cluster have been brought up, verified with `make
test`, and destroyed - both of them, whatever happened during the run. Direct
pushes to `main` are rejected.

The heavy half is opt-in per pull request through the `ci:lifecycle` label,
because a run costs roughly 55 minutes and a little under one US dollar.

The reasoning behind every choice here is in ADR 0035. This spec states the
requirements and how they are verified.

## 2. Scope and non-goals

In scope:

- `.github/workflows/lifecycle-test.yml` — PR trigger, label gate, the
  provider matrix, and the `pr-gate` job.
- `.github/workflows/lifecycle-provider.yml` — the reusable per-provider
  `up`/`test`/`down` chain.
- `.github/actions/setup-lab-tools/` — the shared toolchain install.
- `scripts/verify-no-leaks.sh` — the post-teardown assertion.
- Branch protection on `main` and the repository's merge-method settings.

Non-goals:

- The separate PR-triggered `validate.yml` of SHARED-019. The five static-check
  jobs stay inside `lifecycle-test.yml`; SHARED-019 remains READY.
- AWS-020's `terraform/live/ci/` state tree, its `Ephemeral=true` tag, and its
  scheduled reaper (Requirements 2, 3 and 8) — still deferred, see ADR 0026 and
  ADR 0035 decision 6.
- A cleanup-on-failure step for `lab.yml`'s manual dispatches.
- Triaging `tfsec`'s 41 findings so it can block a merge.

## 3. Requirements

1. Static validation MUST run on every pull request event, and MUST gate the
   lifecycle jobs so a lint failure costs no cloud time.
2. The two-provider lifecycle MUST run only when the pull request carries the
   `ci:lifecycle` label, and applying the label MUST itself start the run
   against the pull request's current head commit.
3. Exactly one job, `pr-gate`, MUST be the required status check. It MUST
   report a decided result for every reachable state and MUST NOT be reachable
   in a pending state (constitution §11).
4. A pull request that changes no infrastructure path MUST pass `pr-gate`
   without the label and without any cloud spend. The path list MUST be
   recorded in ADR 0035, not only in the workflow.
5. A pull request that changes an infrastructure path and carries no label MUST
   fail `pr-gate` with a message naming the label.
6. Untrusted pull requests MUST NOT obtain AWS or Civo credentials
   (constitution §11, AWS-020 R5). Every credentialed job MUST carry an
   explicit same-repository test in addition to the label requirement.
7. Both providers MUST run at the same time and MUST be independent: a failure
   in one MUST NOT prevent the other from completing its own teardown.
8. Every run MUST attempt teardown of both providers even after a failure or a
   cancellation (AWS-020 R6), as a separate job with its own `if: always()`.
9. A teardown MUST be verified, not assumed. Any Bootstrap- or
   Persistent-lifecycle resource surviving `full-down` MUST fail the job.
10. Runs against the same project MUST be serialized against each other and
    against `lab.yml` (constitution §11, AWS-020 R7), using the same
    concurrency group expression `lab.yml` uses.
11. The Civo leg MUST use the Let's Encrypt staging issuer, so per-pull-request
    runs do not consume the production quota shared with the personal lab.
12. Direct pushes, force-pushes and deletion of `main` MUST be rejected
    (SHARED-017 R1, R2).
13. Squash MUST be the only available merge method.

## 4. Deviations from the specs this implements

- **D1 — AWS-020 R5 trigger.** The spec allows "maintainer `workflow_dispatch`,
  or pushes on the main repository". The trigger is now a maintainer-applied
  label on a pull request. Equivalent in trust (labelling needs write access)
  and strictly earlier in the cycle.
- **D2 — AWS-020 R1 sequence.** The run is `full-up` -> `test` -> `full-down`,
  not the full CREATE -> ... -> RECREATE -> VERIFY RECOVERY sequence. The
  recreate half is AWS-020's `mode=resilience`, explicitly not part of a
  routine PR-triggered run (R9). Unchanged from ADR 0026.
- **D3 — AWS-020 R2 isolation.** Isolation is by `PROJECT_NAME`/`SUBDOMAIN`,
  not `terraform/live/ci/`. Unchanged from ADR 0026 decision 1.
- **D4 — SHARED-019 not split out.** Its five checks run here rather than in a
  separate `validate.yml`, and its Requirement 5 gate job is implemented as
  `pr-gate`. Its Requirement 4 path filtering is implemented inside `pr-gate`
  rather than as per-job filters. SHARED-019 stays READY for the split.
- **D5 — two checks added beyond SHARED-019's list.** `make gitops-check` and
  `make specs-check` now gate merges; neither ran in any workflow before.
- **D6 — `tfsec` stays report-only.** `soft_fail: true` is retained, so its 41
  untriaged findings do not block merges.

## 5. Testing / acceptance criteria

1. A pull request with no label runs the six validate jobs, skips `lifecycle`,
   and shows `pr-gate` red naming the label.
2. Adding the label starts a run with no further push; both providers appear.
3. Both `test` jobs pass and both `down` jobs pass, including
   `verify-no-leaks.sh`.
4. After the run, neither CI project has a cluster, state bucket, backup
   bucket, hosted zone or SSM parameter left.
5. A pull request touching only documentation passes `pr-gate` green without
   the label, and no lifecycle job runs.
6. A deliberately broken bring-up on one provider only: that provider's leg
   fails, **the other provider still completes its own teardown**, and
   `pr-gate` is red. This is the proof for Requirement 7.
7. `git push origin main` is rejected once branch protection is applied.
8. The repository offers squash as the only merge method.

## 6. Evidence

To be recorded when the live runs complete.
