# 016 — Branch Protection

**Complexity:** Low
**Risk:** Low — a GitHub repository setting, not an AWS resource; the failure mode is a skipped review, not data loss or cost.
**Estimated cost:** ~1–2 hours · AWS runtime cost: none — this is a GitHub-side setting, not an AWS resource.
**Recommended model:** Sonnet — routine GitHub configuration, no ambiguity.
**Depends on:** none (repository-level GitHub setting; does not require any prior spec's infrastructure)
**Lifecycle class(es) touched:** none — this is not an AWS resource and does not belong to Bootstrap, Persistent, or Disposable.

## Scope

Configures GitHub branch protection on `main` so every change lands through a reviewed pull request:

- Prohibit direct pushes to `main`.
- Require a pull request before merge.
- Prohibit force-pushes and branch deletion on `main`.
- Reserve a slot for a required status check, to be pointed at spec 019's fast-validation workflow once it exists.

Excludes: the fast-validation workflow itself (018 — this spec only reserves the required-check slot; 018 builds the check that fills it), Atlantis's PR plan/apply automation (017), the full lifecycle validation workflow (019).

## Requirements

1. Direct pushes to `main` MUST be prohibited — every change MUST land via a pull request (constitution §11's CI/CD intent applies only if a PR exists to run checks against).
2. Force-pushes to `main` and deletion of `main` MUST be prohibited.
3. This spec MUST be completed before spec 018 (Atlantis) starts consuming PR events — Atlantis's plan-on-PR/apply-on-merge model assumes merges to `main` only happen through reviewed PRs.
4. Once spec 019's fast-validation workflow exists, its status check MUST be added as a required check on `main` — this spec does not block on 018 existing yet, but the required-check setting MUST be revisited and updated when 018 lands, not left permanently empty.
5. Any bypass of the PR requirement (e.g., an emergency admin override) MUST be documented as a deliberate one-time exception, not a silent, repeatable escape hatch.

## Implementation hints

- Configure this manually through the GitHub repository settings UI (Settings → Branches → branch protection rule for `main`), documented here as a one-time bootstrap step — similar in spirit to the manual, one-time NS delegation step in spec 002/ADR 0002. A manual GitHub-side setting avoids introducing a new secret type (a GitHub API token) this early in the roadmap.
- If later specs want this Terraform-managed instead (e.g., via the `integrations/github` Terraform provider once spec 018's automation exists to apply it), that is a reasonable future improvement — record it as a follow-up, not a requirement of this spec.
- Revisit the required-status-check list twice more: once when spec 019 (fast validation) lands, and again if spec 020 (full lifecycle validation) or spec 018 (Atlantis) should also gate merges.

## Testing / acceptance criteria

- Attempting to push a commit directly to `main` is rejected by GitHub.
- Attempting to force-push or delete `main` is rejected by GitHub.
- A pull request against `main` can be merged only after any currently-required status checks pass (initially none, until spec 019 lands).
- No AWS resource or Terraform state is affected by this spec — verified by there being none to check.
