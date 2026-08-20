# 0003 — Atlantis Hosting Location

**Status:** Accepted

## Context

Spec 016 introduces Atlantis to run `terraform plan` on pull requests and `terraform apply` on merge, so Terraform changes go through a reviewed PR instead of a local `terraform apply`. Atlantis needs somewhere to run.

The obvious candidate — hosting it as a workload on the platform's own disposable EKS cluster — creates a chicken-and-egg problem: Atlantis must apply the Terraform that creates, modifies, and destroys that same disposable cluster (spec 003), including `make down` destroying it entirely. A service cannot safely orchestrate the destruction of the compute it runs on, and a `make down` would take Atlantis itself offline, leaving no way to `terraform apply` the very `make up` that would bring it back.

## Decision

Atlantis runs on **Bootstrap-lifecycle** compute — a small, standalone resource (a single EC2 instance or a single ECS Fargate service) created by the bootstrap Terraform stack, independent of EKS. It is rarely destroyed, alongside the other bootstrap resources (state backend, OIDC provider, foundational IAM, KMS).

Atlantis assumes a distinct IAM role per Terragrunt stack (`bootstrap`, `persistent`, `disposable`, `ci/persistent`), matching the least-privilege, per-stack role pattern spec 001 already establishes for other actors. (Superseded in part by ADR 0007: `ci/disposable` is excluded from this list — spec 018's own OIDC-authenticated workflow creates and destroys it on every full-lifecycle run, a test lifecycle rather than a routine Terraform edit, so Atlantis holds no role for it.)

This is a deliberate, explicit exception to constitution §9's general preference for avoiding always-on resources — the always-on cost here is small (a single small instance/task), and the alternative (no automation, or automation that can strand itself) is worse.

## Alternatives considered

**a) Host Atlantis on the disposable EKS cluster (Argo-managed).** Rejected — this is the chicken-and-egg problem itself. Atlantis would need to apply the Terraform that destroys its own host, and `make down` would remove Atlantis before it could ever apply the corresponding `make up`.

**b) No dedicated Atlantis service — GitHub Actions runs `plan`/`apply` directly.** Rejected as the default per the user's explicit request for a PR-driven plan/apply service with native plan-locking and PR-comment `apply` commands; also loses Atlantis's built-in plan locking (preventing two PRs from planning/applying the same stack concurrently) that a set of independent GitHub Actions workflows would have to reimplement.

**c) Bootstrap-lifecycle standalone compute, independent of EKS.** Chosen — Atlantis stays available regardless of the disposable stack's state, so it can apply the Terraform that creates, modifies, or destroys EKS itself without depending on EKS being up.

## Consequences

- One small always-on AWS resource exists outside any `make up`/`make down` cycle, with its own explicit cost line (spec 016, Requirement 3).
- Atlantis's per-stack IAM roles must be created and maintained alongside spec 001's existing per-stack role convention — no new pattern, just one more consumer of it.
- A future migration of Atlantis onto Fargate scale-to-zero, or an on-demand start/stop mechanism, remains open as a cost optimization (see spec 016's implementation hints) without changing this decision's core constraint: Atlantis's host must not be part of the lifecycle Atlantis itself manages.
