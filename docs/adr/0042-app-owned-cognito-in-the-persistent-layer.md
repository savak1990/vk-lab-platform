# ADR 0042: The Ahorro Cognito pool is a platform-owned persistent unit

## Status

Accepted

Extends [ADR 0015](0015-business-app-gitops-topology.md) from an application's
registries and CI role to its identity provider. Supersedes decision 3 of
`vk-ahorro`'s ADR 0001, which placed the pool in the application repository.

## Context

`vk-ahorro` planned its own Terragrunt tree and its own state bucket to create
a Cognito user pool. That plan predates the lifecycle button: `lab.yml` is a
`workflow_dispatch` whose `target` choices include `full-up`, and nothing in
that chain applies another repository's Terraform. The pool would have been
created once, by hand, in a second repository, with a second backend and a
second bootstrap script — and the button would still not deliver a working
application.

ADR 0015 already answered the ownership question for two neighbouring resource
classes:

> CI in each monorepo authenticates to AWS via its own OIDC-trusted IAM role
> ... This role and its trust policy are created by this platform repo's
> Terraform, since IAM and the OIDC provider are this repo's responsibility
> regardless of which repo the workload code lives in.

It also anticipated app-owned units landing in the persistent layer, for
per-application ECR repositories. `terraform/live/account/ahorro-ci-role` is
the shipped precedent, though it landed with no ADR of its own.

The constitution's §1 prohibition is on *business application source code*. A
Terraform unit is not source code, so nothing is bent here. This ADR says so
explicitly rather than leaving it inferred, because the `ahorro-ci-role`
omission should not become the pattern.

## Decision

The user pool, its single app client and its end-to-end test user are created
by `terraform/live/persistent/ahorro-cognito/`. The application repository
holds no Terraform and no state bucket.

**`persistent/`, not `account/`.** The pool holds per-project user data, so one
pool per `PROJECT_NAME` is the correct isolation — a throwaway CI project must
not share a directory of users with the personal lab. `account/` is for what
must exist exactly once per AWS account.

**No deletion protection.** The AWS API refuses `DeleteUserPool` on a protected
pool, and the provider does not deactivate the flag during destroy. An
unconditional `ACTIVE` would fail `full-down` and leak one pool per labelled
CI lifecycle run. `CONFIRM_DESTROY` on `persistent-down` is the guard, and
`make down` does not reach this layer at all.

**No MFA.** With `mfa_configuration` set, `AdminInitiateAuth` returns a
challenge instead of tokens, which breaks the application's scripted token
path and its end-to-end smoke test.

**One app client.** The application's verifier pins a single client id and
rejects a token whose `aud` or `client_id` differs, so a second client would
mint tokens the service refuses. `ALLOW_ADMIN_USER_PASSWORD_AUTH` is reachable
only through a signed AWS API call; the non-admin `ALLOW_USER_PASSWORD_AUTH`,
which anyone holding the public client id could call, stays off.

**Identifiers travel as configuration, secrets travel as secrets.** The pool
id, client id and issuer are public, so they take the route `fqdn` already
takes — SSM, read by `scripts/argo-up.sh`, passed down as Helm parameters — and
not the External Secrets route, which would store public data as secret data.
The test user's password is a real secret: committed as KMS ciphertext under
`secrets/<project>/`, and published to SSM as a `SecureString`, exactly as the
Postgres app password already is.

## Consequences

- `full-up` creates the pool, the client and the test user. `full-down`
  destroys them, and every user in the pool with them. That is acceptable
  while the only user is a test account Terraform recreates. It stops being
  acceptable the moment a real user signs up, which is a separate decision
  with its own protection.
- `lab-role` gains a `cognito-idp` statement scoped to this account's user
  pools. It had none.
- `ahorro-ci-role` is unchanged. The application's `make token` runs from an
  operator's own credentials; the grant it needs to run in CI belongs to the
  spec that puts it there.
- The unit applies on every target, not only on EKS. A Civo or Hetzner cluster
  reaches Cognito through AWS exactly as an EKS one does, so it stays out of
  every `PERSISTENT_EXCLUDE` list, alongside `persistent/secrets`. Only `vpc`
  and `backups` are AWS-target-only.
- `persistent-up` discovers units by directory, but two lists do not, and a new
  unit must join both: `scripts/persistent-down.sh`'s post-destroy verification
  list and `scripts/terraform-check.sh`'s `LIVE_UNITS`.
- **Known mismatch.** `terraform/live/root.hcl` stamps `Scope = "platform"` on
  every unit in the tree, and constitution §16 defines that tag as marking a
  resource "not a business/application service". Every `ahorro-*` unit
  therefore carries a tag that contradicts its purpose, `ahorro-ci-role`
  included. Recorded, not fixed: changing the tagging touches every unit here.
