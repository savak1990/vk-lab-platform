# 015 — GitHub OIDC Provider Bootstrap

**Complexity:** Low

**Risk:** Low — a single account-level, region-agnostic AWS resource; the only real failure mode is accidentally trying to create a second provider for the same URL, which AWS rejects outright.

**Estimated cost:** ~0.5 day · AWS runtime cost: negligible (no compute).

**Recommended model:** Sonnet — well-documented Terraform pattern, low ambiguity.

**Depends on:** 001-bootstrap (KMS key, `default_tags`, `make bootstrap-up`/`down` this spec's unit reuses)

**Lifecycle class(es) touched:** Bootstrap

## Scope

Extracted out of spec 001's original scope amendment (ADR 0007) into its own spec, run immediately before any GitHub Actions workflow is introduced (spec 016):

- One GitHub OIDC provider (`token.actions.githubusercontent.com`), a `terraform/live/bootstrap/github-oidc/` unit — account-level and region-agnostic, created once and reused by every OIDC-authenticated consumer role this platform ever creates (spec 016's personal-lab role, spec 020's CI role). This unit creates no IAM role.

Excludes: every OIDC-trusted IAM role (spec 016's personal-lab role, spec 020's CI role — this spec creates only the shared provider they trust); Atlantis's own compute/IAM (spec 018, which never uses OIDC).

## Requirements

1. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials; no long-lived AWS access keys may be stored as GitHub secrets (constitution §5). This spec creates the one account-level OIDC provider every such role trusts; it does not create any role itself.
2. Exactly one OIDC provider MUST exist per account (constitution §5, ADR 0007) — this spec is its only creator; no other spec (spec 016, spec 020) may create a second one, only roles trusting this one.
3. This resource is Bootstrap-lifecycle: created once, essentially never destroyed by `make up`/`make down`/`make bootstrap-down`, and reused regardless of which AWS region a given stack deploys into.
4. Every resource created here MUST carry the platform's standard tags (constitution §16) via the shared `default_tags` provider configuration in `terraform/live/root.hcl`.

## Implementation hints

- New Terragrunt unit `terraform/live/bootstrap/github-oidc/`, alongside spec 001's `kms` unit, sharing the same `root.hcl` backend/tagging conventions.
- Terraform's `aws_iam_openid_connect_provider` resource with the standard GitHub thumbprint list; no role, no trust policy — those belong to the consumer specs.
- Wire this unit into `make bootstrap-up`/`make bootstrap-down` alongside `kms`, not as a separate Makefile target.

## Testing / acceptance criteria

- The GitHub OIDC provider exists exactly once in the account after `make bootstrap-up` — confirm via `aws iam list-open-id-connect-providers` — and re-running `terraform apply` (or a second `make bootstrap-up`) does not attempt to create a second one.
- No IAM role is created by this spec — verify via `terraform plan` showing only the provider resource.
- Standard tags present on the provider, spot-checked via `aws resourcegroupstaggingapi get-resources` or equivalent.
- No destroy/recreate lifecycle test of its own (Bootstrap is "almost never destroyed"); fast validation (fmt, validate, plan) is sufficient.
