# 0021 — Account-scoped Terraform layer for account-global resources

## Status

Accepted

## Context

Spec 015 places the GitHub OIDC provider at
`terraform/live/bootstrap/github-oidc/` and wires it into `make bootstrap-up`,
alongside the secrets KMS key. Both resources are created once and essentially
never destroyed, so grouping them by lifecycle looks correct.

They differ on a second, independent axis. The KMS key is **per-project**: each
`PROJECT_NAME` needs its own key, and its state lives in that project's own
`${PROJECT_NAME}-tf-state` bucket. The OIDC provider is **per-account**: AWS
permits exactly one provider per issuer URL per account.

That difference is not hypothetical. CI will run `make full-up` with a
PR-specific `PROJECT_NAME` and `SUBDOMAIN`, so each run gets its own state
bucket and therefore an empty state file for the OIDC unit. Terraform sees no
existing resource, issues a create, and AWS rejects it:

```
EntityAlreadyExists: Provider with url
https://token.actions.githubusercontent.com already exists.
```

Every lifecycle command in this repository discovers units by listing the
directory it `cd`s into (`terragrunt run --all`). Scope is therefore only
enforceable through the directory tree — and it was not represented there at
all, so the collision had nowhere to be caught.

Constitution §5 additionally requires the provider never be destroyed by
`make up`/`make down`/`make bootstrap-down`. Living under `bootstrap/` puts it
directly in `scripts/bootstrap-down.sh`'s `run --all destroy`, which would have
needed a guard (`exclude` block or `prevent_destroy`) to prevent.

## Decision

Add `terraform/live/account/` as a top-level layer beside `state/`,
`bootstrap/`, `persistent/`, and `disposable/`, holding account-global
resources only. The GitHub OIDC provider moves there.

A unit belongs in this layer only if exactly one must exist per AWS account
regardless of how many projects or PR environments exist. Being long-lived is
not sufficient — that is what `bootstrap/` is for.

The layer is applied by `make account-up` and destroyed by `make account-down`.
Neither appears in a composite target: not `up`, not `full-up`, not
`bootstrap-up`/`bootstrap-down`.

`account-down` follows `bootstrap-down`'s guard pattern rather than ADR 0004's
"no destroy command at all" treatment of the state bucket: it refuses while
this project has Bootstrap, Persistent, or Disposable state, then defers to
terragrunt's own interactive destroy prompt. That guard can only see
`${PROJECT_NAME}`'s bucket, so it cannot prove no *other* project in the
account still depends on the provider; the script warns and names the account
instead of implying a completeness it does not have.

`account` is a scope, not a lifecycle class. `terraform/live/root.hcl` maps it
onto `Lifecycle=bootstrap`, so constitution §16's tag enum is unchanged.

State stays in `${PROJECT_NAME}-tf-state` rather than a fixed bucket name; a
fork has a different `PROJECT_NAME`, and hardcoding one would break
constitution §19 fork-configurability. The operator runs `make account-up`
once with their primary `PROJECT_NAME`; CI never invokes it.

`scripts/account-up.sh` exits 0 with an explanatory message when a provider
already exists, so re-running is a no-op and the wrong-`PROJECT_NAME` case
produces a clear message about account-vs-project scope instead of an opaque
AWS error.

Separately: `thumbprint_list` is omitted. Verified `optional: true,
computed: true` on the pinned `hashicorp/aws 6.60.0` — AWS validates this
issuer against its own trusted CA library and computes the value, so a pinned
SHA-1 would only rot when GitHub rotates certificates. Spec 015's "standard
GitHub thumbprint list" hint is superseded.

## Consequences

- Spec 015's implementation hints are superseded on all three points: the unit
  path, the thumbprint list, and the `make bootstrap-up` wiring.
- `bootstrap/` and `bootstrap-down.sh` need no exclusion mechanism — a unit
  their `run --all` cannot discover can be neither created nor destroyed by
  them, under any `PROJECT_NAME`. Verified: `terragrunt find` under
  `terraform/live/bootstrap/` lists `kms` only.
- `make state-up` is now a prerequisite of `make account-up` as well as of
  `make bootstrap-up`; the script reuses `scripts/require-state.sh` for it.
- Future account-global resources (an account-wide CloudTrail trail, an IAM
  Access Analyzer, a second OIDC provider for another issuer) have a home and
  need no new Makefile target — the target is named for the layer, not the
  resource.
- ADR 0007's framing of the provider as "part of spec 001" is superseded on
  location; its provider/role split — one provider, per-consumer roles — is
  unchanged and still binding.
- Documentation referring to `bootstrap-up` as the provider's creator
  (`docs/architecture.md` §17a, constitution §5, specs 016 and 020) is updated
  to name `make account-up`.
- Per-PR ephemeral CI environments, which motivated this, still need their own
  ADR superseding ADR 0007's rejection of that model, plus the per-PR
  state/DNS/tag plumbing and cost controls it rejected them for. This ADR does
  not decide that; the layer split is correct under either CI model, since two
  projects in one account are enough to force it.
