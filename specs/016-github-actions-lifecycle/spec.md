# 016 — GitHub Actions Lifecycle (lab-up / lab-down)

**Status:** Implemented — scope grew past the text below during
implementation; see the scope amendment immediately after this line, and
ADR 0022.

> **Scope amendment (ADR 0022):** the two workflows became dashboards rather
> than fixed single-purpose triggers. `lab-up.yml`/`lab-down.yml` take
> `project_name`/`subdomain`/`region` as bounded `type: choice` inputs
> (exactly one option today, `vk-lab-platform`/`lab`/`eu-west-1` — a second
> registered combination needs a second option plus its own role's ARNs,
> added together, deliberately, never accepted as free text — see the ADR for
> why), plus a `depth` selector. `lab-up.yml`'s depth reaches `full-up`
> (State → Bootstrap → Persistent → up), not just `up`; `lab-down.yml`'s
> reaches `down-through-persistent` and `full-down`. `full-down` is gated,
> from day one, by a per-environment allow-list (`scripts/lib/
> ephemeral-confirm.sh`'s `EPHEMERAL_PROJECTS`, empty today) plus IAM
> (`personal-lab-role` has no action that could delete the Bootstrap KMS key
> or State bucket) plus a GitHub Environment (`ephemeral-teardown`) requiring
> reviewer approval on that job — `vk-lab-platform` cannot reach it today, by
> two independent structural reasons, not merely by convention. The personal-
> lab role is also the first to trust a second, Kubernetes-access-only
> identity, `eks-access-identity` (spec 016 creates this too, in the
> account-global layer alongside spec 015's provider) — see ADR 0022 for why
> `enable_cluster_creator_admin_permissions` alone wasn't sufficient.

**Complexity:** Medium
**Risk:** Medium — a workflow that can create/destroy real AWS infrastructure on trigger; wrong trigger scoping or a missing environment gate could let the wrong actor start or tear down the lab.
**Estimated cost:** ~1 day · AWS runtime cost: none beyond whatever `make up`/`make down` already costs when invoked.
**Recommended model:** Sonnet — thin wrapper workflows, low algorithmic complexity, but worth a careful pass on trigger/permission scoping.
**Depends on:** 001-bootstrap (state backend/tagging conventions this spec's own Terraform follows), 015-github-oidc-bootstrap (the GitHub OIDC provider this spec's role trusts), 014-lifecycle (the `make up`/`make down` targets this spec calls)

> **Scope amendment:** the GitHub OIDC **provider** is created once, by
> spec 015 — it's account-level, region-agnostic infrastructure reused by
> every OIDC-authenticated role this platform creates, not something this
> spec owns (ADR 0007). This spec creates only its own **role** trusting
> that existing provider: the personal-lab-scoped "normal deploy" role, in
> addition to the two workflow files below.
**Lifecycle class(es) touched:** none directly — this spec adds CI plumbing only; it triggers Disposable-lifecycle operations already defined by spec 003–013.

## Scope

Gives the platform's lifecycle commands a GitHub Actions entry point, so `make up`/`make down` can be triggered from GitHub and not only from a developer's machine, per architecture.md §34's "Workstation-Initiated and GitHub Lifecycle Equivalence" (this is about the `aws` target run from GitHub vs. a workstation — unrelated to the `local`/minikube-kind target from spec 022):

- A personal-lab-scoped IAM role trusting the GitHub OIDC provider spec 015 creates (in `terraform/live/account/`, applied by `make account-up`) — the first real consumer of GitHub OIDC federation in this platform (spec 018's Atlantis uses its own instance/task role instead, never OIDC).
- `.github/workflows/lab-up.yml` — a manually-triggered (`workflow_dispatch`) workflow that authenticates via that OIDC role and runs `make up`.
- `.github/workflows/lab-down.yml` — the equivalent for `make down`.

Excludes: any PR-triggered validation workflow (`validate.yml`), the Atlantis PR plan/apply automation (spec 018), or the full automated lifecycle test (`platform-integration.yml`) — those are specs 018–019's responsibility, run against CI's own isolated state, not the personal lab's. This spec is specifically about giving the *personal* lab a remote start/stop button that behaves identically to running `make up`/`make down` locally.

## Requirements

1. `lab-up.yml`/`lab-down.yml` MUST be thin wrappers: check out the repo, assume the OIDC role created by this spec, and call the exact same `make up`/`make down` targets a developer would run from their own workstation — no divergent logic between workstation-initiated and GitHub execution (architecture.md §34, constitution's platform invariant #13).
2. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials (constitution §5) — the same requirement that applies to every other GitHub-triggered AWS interaction in this platform, not a special case for these two workflows.
3. These workflows operate on the **personal** lab's persistent/disposable state, not CI's isolated `ci/persistent`/`ci/disposable` state (constitution §11) — the OIDC role they assume MUST be scoped to the personal-lab Terraform state paths, distinct from spec 020's CI-scoped role and from spec 018's per-stack Atlantis roles.
4. Triggering MUST NOT be automatic on every push or PR — these workflows start/stop real, billable infrastructure and MUST require an explicit human action (`workflow_dispatch`, optionally gated by a GitHub Environment with required reviewers) rather than firing on routine repository activity.
5. `make down` runs (whether local or via `lab-down.yml`) MUST still respect every postcondition and safety check spec 014 already defines — this spec adds a trigger, not a second implementation of shutdown logic.
6. `AWS_ROLE_ARN` and `AWS_REGION` MUST be supplied to these workflows as GitHub Environment/repository variables, never hardcoded (constitution §19) — this is what lets a fork owner point `lab-up.yml`/`lab-down.yml` at their own account/role/region with zero source-code changes.
7. This spec MUST create only its own role, trusting the one OIDC provider spec 015 already created. It MUST NOT create a second OIDC provider.

## Implementation hints

- Use `workflow_dispatch` as the trigger for both workflows; consider a required GitHub Environment (e.g. `personal-lab`) with manual approval if an extra confirmation gate before destroying the personal lab is desired.
- Create this spec's IAM role as its own Terraform unit (e.g. `terraform/live/bootstrap/personal-lab-role/`, a Bootstrap-lifecycle unit alongside spec 001's `kms` unit and spec 015's `github-oidc` unit, inheriting the same `root.hcl` tagging/backend conventions), with a `data` lookup or Terragrunt `dependency` reference to spec 015's existing OIDC provider — do not create a second provider here. Trust policy scoped to `repo:<owner>/<repo>:*` with a `sub` condition, not a blanket `repo:*:*` trust, and permissions limited to the personal-lab persistent/disposable state paths.
- Authenticate with `aws-actions/configure-aws-credentials` using this spec's own OIDC role — do not reuse the CI-scoped role from spec 020 or Atlantis's per-stack roles from spec 018.
- Keep the workflow YAML itself minimal: checkout → configure AWS credentials → `make up` (or `make down`) → surface the command's own output/logs as the workflow's result, rather than re-implementing any status reporting spec 014 already does.
- If a Slack/notification step is ever desired for lab up/down events, add it as a clearly optional, separate step — it's not required for this spec's acceptance criteria.

## Testing / acceptance criteria

> **Scope amendment (ADR 0022):** see `tests/manual/016-lab-up-down.md` for the
> full manual test plan covering the bounded-environment/depth-selector scope
> this spec grew into (the `up`/`full-up`/`down`/`down-through-persistent`/
> `full-down` matrix, the workstation/GitHub Kubernetes-access equivalence via
> `eks-access-identity`, the full-down refusal for `vk-lab-platform`, and
> fault-injection cases). The criteria below are the original, narrower set;
> still true, just no longer the whole picture.

- Manually triggering `lab-up.yml` from the GitHub Actions UI produces the same healthy end state as running `make up` locally (verified against spec 014's own health checks).
- Manually triggering `lab-down.yml` produces the same clean teardown as running `make down` locally, including all of spec 014's postcondition checks passing.
- Neither workflow fires on a routine `git push` or pull request — confirm by pushing a commit and a PR and observing no lab-up/lab-down run is triggered.
- The OIDC role these workflows assume cannot touch `ci/persistent`/`ci/disposable` state (verify via IAM policy scoping, not just convention).
- Fast validation (GitHub Actions workflow YAML validation) applies to these workflow files like any other change under `.github/workflows/`.
