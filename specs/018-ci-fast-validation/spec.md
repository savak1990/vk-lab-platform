# 018 — CI Fast Validation

**Complexity:** Medium
**Risk:** Low — read-only checks, no AWS credentials, no real infrastructure touched.
**Estimated cost:** ~1 day · AWS runtime cost: none — this workflow performs no `terraform plan`/`apply` and requests no AWS credentials.
**Recommended model:** Sonnet — well-documented static-check tooling, low ambiguity.
**Depends on:** 016-branch-protection (this workflow becomes the required status check reserved there)
**Lifecycle class(es) touched:** none — this workflow reads and lints source; it does not create, modify, or destroy any AWS or Kubernetes resource.

## Scope

Implements `.github/workflows/validate.yml`, running on every pull-request update, per architecture.md §26:

- Terraform formatting and validation, Terragrunt validation.
- Helm template rendering and Kubernetes schema validation.
- YAML linting.
- Security/static scanning (e.g., secret-scanning, `tfsec`/`checkov`).
- Argo manifest validation for anything under `gitops/`.
- GitHub Actions workflow validation (e.g., `actionlint`) for anything under `.github/workflows/`.

Excludes: `terraform plan` against real state — that runs inside Atlantis (spec 017), which already comments plan output on the same PR; duplicating it here would produce two conflicting plan outputs and would require this workflow to hold AWS credentials it does not otherwise need. Also excludes the manually-triggered full lifecycle test (019).

## Requirements

1. Every pull request MUST receive this fast validation before merge (constitution §11) — spec 016 wires this workflow's result in as a required status check on `main`.
2. This workflow MUST perform read-only checks only (formatting, validation, linting, schema checks, static scanning). It MUST NOT call `terraform plan` or `terraform apply` against real state — that responsibility belongs to Atlantis (spec 017), so plan output is never duplicated or contradicted between two tools.
3. This workflow MUST NOT request AWS credentials of any kind, since none of its checks touch real AWS state — confirm no OIDC role is configured for this workflow.
4. Documentation-only changes SHOULD skip infrastructure-specific checks where practical (e.g., path filters), so this workflow stays fast for the changes it doesn't need to check.

## Implementation hints

- `terraform fmt -check` and `terraform validate` per stack; `terragrunt validate --terragrunt-non-interactive`.
- `helm template` followed by a Kubernetes schema validator (e.g., `kubeconform`) for each chart under `gitops/`.
- `yamllint` across `gitops/`, `terraform/`, and `.github/workflows/`.
- A static security scanner (e.g., `tfsec` or `checkov`) for Terraform, and a secret-scanning step over the diff, per constitution §5.
- `actionlint` for every file under `.github/workflows/`.
- Use GitHub Actions path filters so a documentation-only PR skips the Terraform/Helm-specific steps.

## Testing / acceptance criteria

- A documentation-only pull request completes this workflow quickly, without running the Terraform/Helm-specific steps.
- A pull request that changes a file under `terraform/**` runs the full check set and fails on a deliberately broken `terraform fmt` or a deliberately invalid Helm value.
- Inspecting the workflow run confirms no AWS credentials were requested or used.
- A pull request cannot merge into `main` while this check is failing (confirmed via spec 016's required-status-check setting).
