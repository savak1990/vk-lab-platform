---
id: "AWS-035"
status: "IN_PROGRESS"
updated: "2026-09-26"
---
# 035 — Ahorro Cognito user pool

**Status note:** Implemented; becomes DONE once applied and verified against a real pool.

**Complexity:** Small
**Risk:** Low — one new persistent unit with no dependency on any other; it creates nothing another unit reads.
**Estimated cost:** ~0.5 day · AWS runtime cost: Cognito Essentials, free below 10,000 monthly active users. SSM standard parameters are free.
**Recommended model:** Sonnet.
**Depends on:** 002-persistent-foundation (the persistent layer and its secrets pattern), 013-secrets (the KMS ciphertext convention), ADR 0015, ADR 0042.
**Lifecycle class(es) touched:** Persistent.

## Scope

One Terragrunt unit, `terraform/live/persistent/ahorro-cognito/`, creating the
identity provider the `vk-ahorro` application authenticates against: a user
pool, one app client, and one end-to-end test user, plus the SSM parameters a
consumer reads them from.

Excludes: any Kubernetes object; the application's GitOps pointer (that is the
`vk-ahorro` repository's own spec 060); carrying the identifiers into a running
cluster through `scripts/argo-up.sh`; any grant to `ahorro-ci-role`.

## Requirements

1. The unit MUST live at `terraform/live/persistent/ahorro-cognito/` and source `terraform/modules/ahorro-cognito`, with `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and a committed `.terraform.lock.hcl`, pinning `required_version = "= 1.15.9"` and `hashicorp/aws = "= 6.60.0"` like every other module.
2. The pool MUST be named `${PROJECT_NAME}-ahorro`, use email as the username attribute, auto-verify email, require the `email` and `name` attributes, and enforce a password policy of minimum length 8 with lowercase, uppercase and numbers.
3. `deletion_protection` MUST be `INACTIVE` and no `mfa_configuration` MUST be set. Both are load-bearing: the AWS API refuses `DeleteUserPool` on a protected pool, so `full-down` would fail and the label-gated lifecycle test would leak one pool per run; and MFA makes `AdminInitiateAuth` return a challenge instead of tokens, breaking the consumer's scripted sign-in (ADR 0042).
4. There MUST be exactly one app client, `vk-ahorro-app`, with `generate_secret = false`, `explicit_auth_flows = [ALLOW_USER_SRP_AUTH, ALLOW_ADMIN_USER_PASSWORD_AUTH, ALLOW_REFRESH_TOKEN_AUTH]`, id and access token validity 1 hour, refresh 30 days, and `prevent_user_existence_errors = ENABLED`. The non-admin `ALLOW_USER_PASSWORD_AUTH` MUST NOT be enabled: it is callable by anyone holding the public client id.
5. One test user MUST be created from the KMS ciphertext `secrets/${PROJECT_NAME}/ahorro-test-user-password.enc`, with `message_action = SUPPRESS` and a permanent password so it lands `CONFIRMED`. Its username is a fixed non-deliverable address — nothing is ever sent to it.
6. The unit MUST publish, under `/${PROJECT_NAME}/persistent/ahorro-cognito/` (ADR 0023): `user_pool_id`, `client_id`, `issuer` and `test_user_email` as `String`, and `test_user_password` as a `SecureString` under `alias/lab-secrets`. The first three are public identifiers; only the password is a secret.
7. `scripts/generate-secrets.sh` MUST mint the test password when it is missing, and `scripts/require-persistent-secrets.sh` MUST fail fast when it is, matching how `postgres-app-password` is already handled. Without both, a bring-up for a fresh `PROJECT_NAME` fails inside `terragrunt run --all` on a raw `filebase64()` error.
8. `lab-role` MUST gain a `cognito-idp` statement scoped to `arn:aws:cognito-idp:*:<account>:userpool/*`, plus `ListUserPools` on `*` because that action takes no resource-level scoping. It had no Cognito permission at all, so the lifecycle button could not apply or destroy this unit.
9. The unit MUST apply on every target, so it MUST NOT be added to any `PERSISTENT_EXCLUDE` list. Cognito is reached through AWS on a Civo or Hetzner cluster exactly as it is on EKS, the same way `persistent/secrets` already applies everywhere; only `vpc` and `backups` are AWS-target-only. It MUST be added to `scripts/persistent-down.sh`'s post-destroy verification list and to `scripts/terraform-check.sh`'s `LIVE_UNITS`: `persistent-up` discovers by directory, but those two lists do not.
10. The unit MUST NOT declare a `dependency` block, so `terraform-check.sh` can validate it with `-backend=false`.

## Implementation hints

- `aws_cognito_user` takes `password` (permanent) rather than `temporary_password`; the latter leaves the user in `FORCE_CHANGE_PASSWORD` and a scripted sign-in then fails on a challenge.
- `data.aws_kms_secrets` with `filebase64()` is the same decryption path `terraform/modules/persistent-secrets` already uses.
- The issuer is `https://cognito-idp.<region>.amazonaws.com/<pool id>`; the application derives its JWKS endpoint from it and needs no region of its own.

## Testing / acceptance criteria

- `make terraform-check` passes, with `persistent/ahorro-cognito` in its `LIVE_UNITS` output.
- `make persistent-up` then a second `terragrunt plan` shows no changes.
- `aws ssm get-parameters-by-path --path /<project>/persistent/ahorro-cognito` returns five parameters, exactly one of type `SecureString`.
- `aws cognito-idp describe-user-pool` shows `DeletionProtection: INACTIVE`, `MfaConfiguration: OFF`, and one app client.
- `aws cognito-idp list-users` shows the test user with `UserStatus: CONFIRMED`, not `FORCE_CHANGE_PASSWORD`.
- `aws cognito-idp admin-initiate-auth --auth-flow ADMIN_USER_PASSWORD_AUTH` against the client returns an id token; `initiate-auth --auth-flow USER_PASSWORD_AUTH` against the same client is rejected.
- A `ci:lifecycle-aws` run on the pull request completes `full-up` → `test` → `full-down` with no pool left behind, proving the destroy path.
