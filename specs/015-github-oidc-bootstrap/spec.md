# 015 — GitHub OIDC Provider Bootstrap

**Status:** Implemented — the unit lives in the account layer, not the Bootstrap stack, and omits `thumbprint_list` (ADR 0021 supersedes the original implementation hints).

**Complexity:** Low

**Risk:** Low — a single account-level, region-agnostic AWS resource; the only real failure mode is accidentally trying to create a second provider for the same URL, which AWS rejects outright.

**Estimated cost:** ~0.5 day · AWS runtime cost: negligible (no compute).

**Recommended model:** Sonnet — well-documented Terraform pattern, low ambiguity.

**Depends on:** 001-bootstrap (KMS key, `default_tags`, `make bootstrap-up`/`down` this spec's unit reuses)

**Lifecycle class(es) touched:** Bootstrap

## Scope

Extracted out of spec 001's original scope amendment (ADR 0007) into its own spec, run immediately before any GitHub Actions workflow is introduced (spec 016):

- One GitHub OIDC provider (`token.actions.githubusercontent.com`), a `terraform/live/account/github-oidc/` unit — account-level and region-agnostic, created once and reused by every OIDC-authenticated consumer role this platform ever creates (spec 016's personal-lab role, spec 020's CI role). This unit creates no IAM role.

Scope amendment (ADR 0021): the unit lives in a new account-global `terraform/live/account/` layer rather than under `bootstrap/`, applied by its own `make account-up`/`make account-down`. Every Bootstrap resource is per-project (its state lives in that project's `${PROJECT_NAME}-tf-state` bucket), but this provider is per-account — so a CI or PR environment running the Bootstrap stack under a different `PROJECT_NAME` would attempt a duplicate provider and be rejected by AWS with `EntityAlreadyExists`.

Excludes: every OIDC-trusted IAM role (spec 016's personal-lab role, spec 020's CI role — this spec creates only the shared provider they trust); Atlantis's own compute/IAM (spec 018, which never uses OIDC).

## Requirements

1. GitHub Actions → AWS authentication MUST use OIDC and temporary credentials; no long-lived AWS access keys may be stored as GitHub secrets (constitution §5). This spec creates the one account-level OIDC provider every such role trusts; it does not create any role itself.
2. Exactly one OIDC provider MUST exist per account (constitution §5, ADR 0007) — this spec is its only creator; no other spec (spec 016, spec 020) may create a second one, only roles trusting this one.
3. This resource is Bootstrap-lifecycle: created once, essentially never destroyed by `make up`/`make down`/`make bootstrap-down`, and reused regardless of which AWS region a given stack deploys into — or which `PROJECT_NAME` a given stack runs under.
4. Every resource created here MUST carry the platform's standard tags (constitution §16) via the shared `default_tags` provider configuration in `terraform/live/root.hcl`.

## Implementation hints

- New Terragrunt unit `terraform/live/account/github-oidc/` in its own account-global layer, sharing `root.hcl`'s backend/tagging conventions. `root.hcl` maps the `account/` path onto `Lifecycle=bootstrap` — `account` is a scope, not a new lifecycle class.
- Terraform's `aws_iam_openid_connect_provider` resource; no role, no trust policy — those belong to the consumer specs. Omit `thumbprint_list`: it is `optional` and `computed` on the pinned `hashicorp/aws 6.60.0`, since AWS validates this issuer against its own trusted CA library. A pinned SHA-1 would only rot when GitHub rotates certificates.
- Give it its own `make account-up`/`make account-down`, in no composite target — not `up`, not `full-up`, not `bootstrap-up`. Because both Bootstrap targets discover units by listing `terraform/live/bootstrap/`, a unit outside that directory needs no `exclude` block or `prevent_destroy` to satisfy requirement 3.

## Testing / acceptance criteria

- The GitHub OIDC provider exists exactly once in the account after `make account-up` — confirm via `aws iam list-open-id-connect-providers` — and a second `make account-up` does not attempt to create another (the script detects the existing provider and exits without applying).
- `terragrunt find` under `terraform/live/bootstrap/` does not list the OIDC unit, proving `make bootstrap-up` and `make bootstrap-down` can neither create nor destroy it under any `PROJECT_NAME`.
- No IAM role is created by this spec — verify via `terraform plan` showing only the provider resource.
- Standard tags present on the provider, spot-checked via `aws resourcegroupstaggingapi get-resources` or equivalent.
- No destroy/recreate lifecycle test of its own (Bootstrap is "almost never destroyed"); fast validation (fmt, validate, plan) is sufficient.
