# 015 — GitHub Actions Lifecycle (lab-up / lab-down)

**Complexity:** Medium
**Risk:** Medium — a workflow that can create/destroy real AWS infrastructure on trigger; wrong trigger scoping or a missing environment gate could let the wrong actor start or tear down the lab.
**Estimated cost:** ~1 day · AWS runtime cost: none beyond whatever `make up`/`make down` already costs when invoked.
**Recommended model:** Sonnet — thin wrapper workflows, low algorithmic complexity, but worth a careful pass on trigger/permission scoping.
**Depends on:** 001-bootstrap (OIDC role for this workflow), 014-lifecycle (the `make up`/`make down` targets this spec calls)
**Lifecycle class(es) touched:** none directly — this spec adds CI plumbing only; it triggers Disposable-lifecycle operations already defined by spec 003–014.

## Scope

Gives the platform's lifecycle commands a GitHub Actions entry point, so `make up`/`make down` can be triggered from GitHub and not only from a developer's machine, per architecture.md §34's "Local and GitHub Lifecycle Equivalence":

- `.github/workflows/lab-up.yml` — a manually-triggered (`workflow_dispatch`) workflow that authenticates via OIDC (spec 001's role) and runs `make up`.
- `.github/workflows/lab-down.yml` — the equivalent for `make down`.

Excludes: any PR-triggered validation workflow (`validate.yml`), the Atlantis PR plan/apply automation (spec 017), or the full automated lifecycle test (`platform-integration.yml`) — those are specs 017–019's responsibility, run against CI's own isolated state, not the personal lab's. This spec is specifically about giving the *personal* lab a remote start/stop button that behaves identically to running `make up`/`make down` locally.

## Requirements

1. `lab-up.yml`/`lab-down.yml` MUST be thin wrappers: check out the repo, assume the OIDC role from spec 001, and call the exact same `make up`/`make down` targets a developer would run locally — no divergent logic between local and GitHub execution (architecture.md §34, constitution's platform invariant #13).
2. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials (constitution §5) — the same requirement that applies to every other GitHub-triggered AWS interaction in this platform, not a special case for these two workflows.
3. These workflows operate on the **personal** lab's persistent/disposable state, not CI's isolated `ci/persistent`/`ci/disposable` state (constitution §11) — the OIDC role they assume MUST be scoped to the personal-lab Terraform state paths, distinct from spec 019's CI-scoped role and from spec 017's per-stack Atlantis roles.
4. Triggering MUST NOT be automatic on every push or PR — these workflows start/stop real, billable infrastructure and MUST require an explicit human action (`workflow_dispatch`, optionally gated by a GitHub Environment with required reviewers) rather than firing on routine repository activity.
5. `make down` runs (whether local or via `lab-down.yml`) MUST still respect every postcondition and safety check spec 014 already defines — this spec adds a trigger, not a second implementation of shutdown logic.

## Implementation hints

- Use `workflow_dispatch` as the trigger for both workflows; consider a required GitHub Environment (e.g. `personal-lab`) with manual approval if an extra confirmation gate before destroying the personal lab is desired.
- Authenticate with `aws-actions/configure-aws-credentials` using the OIDC role scoped to the personal-lab state paths from spec 001 — do not reuse the CI-scoped role from spec 019 or Atlantis's per-stack roles from spec 017.
- Keep the workflow YAML itself minimal: checkout → configure AWS credentials → `make up` (or `make down`) → surface the command's own output/logs as the workflow's result, rather than re-implementing any status reporting spec 014 already does.
- If a Slack/notification step is ever desired for lab up/down events, add it as a clearly optional, separate step — it's not required for this spec's acceptance criteria.

## Testing / acceptance criteria

- Manually triggering `lab-up.yml` from the GitHub Actions UI produces the same healthy end state as running `make up` locally (verified against spec 014's own health checks).
- Manually triggering `lab-down.yml` produces the same clean teardown as running `make down` locally, including all of spec 014's postcondition checks passing.
- Neither workflow fires on a routine `git push` or pull request — confirm by pushing a commit and a PR and observing no lab-up/lab-down run is triggered.
- The OIDC role these workflows assume cannot touch `ci/persistent`/`ci/disposable` state (verify via IAM policy scoping, not just convention).
- Fast validation (GitHub Actions workflow YAML validation) applies to these workflow files like any other change under `.github/workflows/`.
