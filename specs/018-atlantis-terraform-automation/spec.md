# 017 — Atlantis Terraform Automation

**Complexity:** High
**Risk:** High — this service gets IAM permission to run `terraform apply` against every lifecycle stack, including the ones that create/destroy EKS itself; a scoping mistake has real blast radius, and getting the hosting model wrong recreates the exact chicken-and-egg problem this spec exists to avoid.
**Estimated cost:** ~2 days · AWS runtime cost: one small always-on compute resource (see Requirement 3) — budget a few dollars/month, and treat that cost as a deliberate, justified exception to the "avoid always-on resources" cost rule.
**Recommended model:** Opus — the hosting-location decision and per-stack IAM scoping both carry real correctness/security risk, not routine Terraform module usage.
**Depends on:** 001-bootstrap (state backend and per-stack IAM role convention — Atlantis does not use GitHub OIDC; it authenticates via its own compute's instance/task role plus `sts:AssumeRole`, unlike spec 017's OIDC-based workflows), 017-branch-protection (Atlantis's plan/apply-on-merge model assumes `main` only changes through reviewed PRs)
**Lifecycle class(es) touched:** Bootstrap (Atlantis's own compute and IAM roles)

## Scope

Installs [Atlantis](https://www.runatlantis.io/) as the service that runs `terraform plan` automatically on pull requests and `terraform apply` on merge (or on an explicit PR comment, per the chosen workflow mode), so Terraform changes across every lifecycle stack go through a reviewed, auditable PR instead of a local `terraform apply`:

- A small, standalone compute resource for Atlantis — **not** hosted on the disposable EKS cluster (see Requirement 1's chicken-and-egg rationale) — created by the bootstrap Terraform stack.
- A GitHub App (preferred over a personal access token) granting Atlantis webhook access to this repository.
- One IAM role per Terragrunt stack (`bootstrap`, `persistent`, `disposable`, `ci/persistent`) that Atlantis assumes per-project, mirroring spec 001's per-stack role split. `ci/cluster` is deliberately excluded here: spec 020's own workflow creates and destroys it on every full-lifecycle run, via its own OIDC-authenticated role. That's a test lifecycle, not a routine Terraform edit — Atlantis's plan-on-PR/apply-on-merge model doesn't fit it, so Atlantis holds no role for it.
- An `atlantis.yaml` repo config defining one Atlantis "project" per Terragrunt stack, each mapped to its own working directory and IAM role.
- A short ADR recording the hosting-location decision and why EKS-hosting was rejected.

Excludes: the fast, lint-only PR checks that don't need real AWS credentials (018 — those run independently of Atlantis, on every PR, even ones Atlantis has nothing to plan); the kind-based GitOps integration test (023 — no AWS involved at all); the manually-triggered full create→destroy→recreate→destroy lifecycle test (019 — Atlantis only ever runs ordinary `plan`/`apply` against the platform's own stable stacks, it does not orchestrate or hold any role for that test's `ci/cluster` environment); any Kubernetes/GitOps resource (Argo CD's job, constitution §2 — Atlantis touches Terraform/Terragrunt state only, never `gitops/`).

Atlantis's routine plan/apply role and spec 020's privileged full-environment-test role are deliberately separate mechanisms serving different purposes: Atlantis reviews and applies ordinary Terraform edits to stable stacks via its own instance/task role (no OIDC); spec 020 stands up and tears down an entire ephemeral AWS environment per PR via its own OIDC-authenticated role (architecture.md §17a). Neither substitutes for the other.

## Requirements

1. Atlantis's own compute MUST be Bootstrap-lifecycle (constitution §3) and MUST NOT run on the disposable EKS cluster. Rationale: Atlantis must remain available to apply the Terraform that creates, modifies, or destroys that same disposable cluster; a service cannot safely orchestrate the destruction of its own host.
2. Atlantis MUST use a dedicated IAM role per Terragrunt stack (`bootstrap`, `persistent`, `disposable`, `ci/persistent`), least-privilege per stack — MUST NOT use one broad role with access across all state paths. Atlantis MUST NOT hold a role for `ci/cluster`. Spec 019's own workflow applies and destroys that state on every full-lifecycle run, using spec 020's own OIDC role (§17a of architecture.md) — never through Atlantis's plan/apply-on-merge flow.
3. Atlantis's always-on compute is an explicit, justified exception to constitution §9's "new always-on resources require explicit justification" rule — record the chosen instance size and its monthly cost here, and evaluate whether it can be stopped when not in use for a personal lab used intermittently.
4. Atlantis MUST run `plan` automatically when a pull request touching `terraform/**` is opened or updated, and MUST run `apply` only after this repository's required PR approval (spec 017) — MUST NOT apply automatically on every push without review.
5. Atlantis's own credentials (GitHub App, AWS role assumption) MUST avoid long-lived static credentials where avoidable (constitution §5) — prefer an instance role or equivalent temporary-credential mechanism over static AWS keys stored in Atlantis's configuration.
6. Atlantis MUST only orchestrate Terraform/Terragrunt stacks. It MUST NOT receive Kubernetes credentials and MUST NOT apply anything under `gitops/` (constitution §2) — that boundary stays with Argo CD.
7. Every AWS resource created for Atlantis MUST carry the platform's standard tags (constitution §16) with `Lifecycle=bootstrap`.
8. The hosting-location decision (Requirement 1) MUST be recorded as an ADR before or alongside this spec (constitution §13).

## Implementation hints

- Run Atlantis as a container on a single small EC2 instance or a single ECS Fargate service — either way, Atlantis needs one persistent process (it holds PR-lock state and a working directory), so plan for a small always-on cost regardless of which compute type is chosen.
- Front the webhook endpoint with an ALB or API Gateway, restricting inbound traffic to GitHub's published webhook IP ranges.
- Configure `atlantis.yaml` with one project per Terragrunt stack; use Atlantis's per-project `workflow`/IAM-role configuration to assume the correct stack-scoped role for each plan/apply, mirroring spec 001's per-stack role split exactly.
- Create a GitHub App scoped to this repository only, rather than a personal access token, for Atlantis's repository access.
- If cost is a concern for intermittent personal-lab use, consider a stop/start pattern (e.g., a small Lambda triggered by the GitHub webhook that starts a stopped EC2 instance on demand) instead of running Atlantis 24/7 — record whichever choice is made and why.

## Testing / acceptance criteria

- Opening a pull request that changes a file under `terraform/**` produces an automatic `atlantis plan` comment on that PR within a few minutes.
- Merging that PR (after spec 017's required approval) triggers `atlantis apply` (or an explicit `atlantis apply` PR comment, per the chosen workflow mode), applying only the intended stack.
- Atlantis's IAM role for the disposable stack cannot assume the persistent or bootstrap stack's role, and vice versa — confirm via IAM policy inspection, not just convention.
- A full `make down`/`make up` cycle of the disposable EKS stack completes successfully, and Atlantis is still usable to plan/apply the next PR afterward — this is the specific test that proves the chicken-and-egg concern from Requirement 1 is resolved.
- Fast validation (Terraform fmt/validate) applies to Atlantis's own Terraform and `atlantis.yaml` like any other change.
