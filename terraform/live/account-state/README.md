# Account state layer

Creates the Terraform remote-state S3 bucket the Account layer
(`terraform/live/account/*`) stores its own state in — never a project's
`${PROJECT_NAME}-tf-state` (see `terraform/live/state/README.md` for that
one). Named `${github_repo_owner}-account-tf-state`, derived from `GITHUB_REPO`,
not `PROJECT_NAME`.

Kept as its own top-level directory, a sibling of `account/` rather than
nested inside it, for the same reason `terraform/live/state/` sits outside
`bootstrap/`: `terragrunt run --all destroy` in `account/`
(`scripts/account-down.sh`) must never discover this unit and try to destroy
the very bucket its own Terraform state lives in.

Like every unit under `account/`, this bucket lives in `ACCOUNT_MAIN_REGION`
(defaults `eu-west-1`), not whatever `REGION` a project happens to be using.

## Usage

`scripts/account-up.sh` calls `scripts/account-state-up.sh` as its first
step — there's no separate manual invocation in the normal flow.
`scripts/account-down.sh` calls `scripts/account-state-down.sh` as its last
step, after the account/ units themselves are destroyed and `CONFIRM_DESTROY`
has already gated the whole run. Both mirror `state-up.sh`/`state-down.sh`'s
mechanics exactly (two-phase local-then-migrate bootstrap; raw AWS API
purge-then-delete on teardown, since Terraform can't destroy the bucket
holding its own state).
