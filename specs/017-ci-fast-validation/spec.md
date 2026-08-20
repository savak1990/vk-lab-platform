# 017 — CI Fast Validation

**Complexity:** Medium
**Risk:** Low — read-only checks, no AWS credentials, no real infrastructure touched.
**Estimated cost:** ~1 day · AWS runtime cost: none — this workflow performs no `terraform plan`/`apply` and requests no AWS credentials.
**Recommended model:** Sonnet — well-documented static-check tooling, low ambiguity.
**Depends on:** 015-branch-protection (this workflow becomes the required status check reserved there)
**Lifecycle class(es) touched:** none — this workflow reads and lints source; it does not create, modify, or destroy any AWS or Kubernetes resource.

## Scope

Implements `.github/workflows/validate.yml`, running on every pull-request update, per architecture.md §26:

- Terraform formatting and validation, Terragrunt validation.
- Helm template rendering and Kubernetes schema validation, for both `values-aws.yaml` and `values-local.yaml` on every `gitops/` component (spec 020 Requirement 17).
- YAML linting.
- Security/static scanning (e.g., secret-scanning, `tfsec`/`checkov`).
- Argo manifest validation for anything under `gitops/`.
- GitHub Actions workflow validation (e.g., `actionlint`) for anything under `.github/workflows/`.

Excludes: `terraform plan` against real state — that runs inside Atlantis (spec 016), which already comments plan output on the same PR; duplicating it here would produce two conflicting plan outputs and would require this workflow to hold AWS credentials it does not otherwise need. Also excludes the manually-triggered full lifecycle test (018) and the kind-based GitOps integration test (022) — that one spins up a real (if AWS-free) cluster and isn't "fast" in the same sense as the checks here, so it's a separate workflow, gated the same way as 018 (trusted-context PRs only), not folded into this one.

## Requirements

1. Every pull request MUST receive this fast validation before merge (constitution §11) — spec 015 wires this workflow's result in as a required status check on `main`.
2. This workflow MUST perform read-only checks only (formatting, validation, linting, schema checks, static scanning). It MUST NOT call `terraform plan` or `terraform apply` against real state — that responsibility belongs to Atlantis (spec 016), so plan output is never duplicated or contradicted between two tools.
3. This workflow MUST NOT request AWS credentials of any kind, since none of its checks touch real AWS state — confirm no OIDC role is configured for this workflow. This includes the `values-local.yaml` rendering check added above: it MUST use dummy/placeholder secret values, never the opt-in real-secrets KMS-decrypt path from spec 020 Requirement 12, which stays entirely out of scope for this workflow.
4. Documentation-only changes SHOULD skip infrastructure-specific checks where practical (e.g., path filters), so this workflow stays fast for the changes it doesn't need to check.
5. This workflow MUST expose an always-running gate job that is itself the required GitHub status check (constitution §11) — it determines which change categories (Terraform, GitOps/Helm, documentation-only) apply to the PR and reports a result (pass or explicit skip) for each, fanning out to the path-filtered sub-jobs from Requirement 4 rather than exposing any of them directly as a required check. This is what keeps a documentation-only PR from leaving a Terraform- or Helm-specific required check permanently pending.

## Implementation hints

- `terraform fmt -check` and `terraform validate` per stack; `terragrunt validate --terragrunt-non-interactive`.
- `helm template` followed by a Kubernetes schema validator (e.g., `kubeconform`) for each chart under `gitops/`.
- `yamllint` across `gitops/`, `terraform/`, and `.github/workflows/`.
- A static security scanner (e.g., `tfsec` or `checkov`) for Terraform, and a secret-scanning step over the diff, per constitution §5.
- `actionlint` for every file under `.github/workflows/`.
- Use GitHub Actions path filters so a documentation-only PR skips the Terraform/Helm-specific steps.
- Implement the gate (Requirement 5) as a small job that runs `dorny/paths-filter` (or equivalent) and always exits successfully itself, recording which categories matched as job outputs — downstream path-filtered jobs key off those outputs, and only the gate job (not the path-filtered jobs) is configured as the branch's required check (spec 015).

## Testing / acceptance criteria

- A documentation-only pull request completes this workflow quickly, without running the Terraform/Helm-specific steps, and the gate job itself reports success (not "skipped" in a way that leaves the required check pending).
- A pull request that changes a file under `terraform/**` runs the full check set and fails on a deliberately broken `terraform fmt` or a deliberately invalid Helm value.
- Inspecting the workflow run confirms no AWS credentials were requested or used.
- A pull request cannot merge into `main` while this check is failing (confirmed via spec 015's required-status-check setting).
