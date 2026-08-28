# Account stack

Account-global resources: created once per AWS account and shared by every
project, every fork owner's lab, and every ephemeral CI environment in that
account.

## Why this is separate from `bootstrap/`

Both layers hold resources that are created once and essentially never
destroyed, so grouping them by lifecycle looks right. They differ on a second,
independent axis: **scope**.

The `bootstrap` KMS key is per-project — each `PROJECT_NAME` needs its own key,
and its Terraform state lives in that project's own `${PROJECT_NAME}-tf-state`
bucket. The GitHub OIDC provider is per-account: AWS permits exactly one
provider per issuer URL per account, no matter how many projects exist.

Putting an account-global resource in a project-scoped layer breaks as soon as
a second project runs `make bootstrap-up` in the same account. That run gets a
fresh, empty state file, issues a create, and AWS rejects it with
`EntityAlreadyExists`. Since `make bootstrap-up` and `scripts/bootstrap-down.sh`
both discover units by listing the directory they `cd` into, keeping this layer
outside `bootstrap/` makes the resource unreachable to them by construction —
no `exclude` block or `prevent_destroy` guard needed.

## What belongs here

A unit belongs in this layer only if it is account-global: exactly one must
exist per AWS account regardless of how many projects or PR environments do.
Being long-lived is not sufficient — that is what `bootstrap/` is for.

Qualifies: the GitHub OIDC provider, an account-wide CloudTrail trail, an IAM
Access Analyzer. Does not qualify: the secrets KMS key (one per project).

## Prerequisite: the `state` layer must already exist

`terraform/live/state/` creates the Terraform state bucket every unit in this
repository — including this one — stores its state in. Run `make state-up`
once, first. `scripts/account-up.sh` checks this and fails with a clear
message rather than an opaque backend-init error.

## Usage

```
make account-up       # run once per AWS account, from a workstation
make account-down     # guarded, expected to run essentially never
```

Run `make account-up` with your primary `PROJECT_NAME`, since this layer's
state lands in that project's bucket. Never run it with a CI or per-PR
`PROJECT_NAME` — the resource is shared, so a second project must reuse it,
not recreate it. Re-running is a no-op: the script detects an existing
provider and exits without applying.

Neither target appears in a composite target: not `up`, not `full-up`, not
`bootstrap-up`/`bootstrap-down`.

`make account-down` refuses while this project still has Bootstrap, Persistent,
or Disposable state, then hands off to terragrunt's own interactive destroy
prompt. Note the limit of that guard: it can only see `${PROJECT_NAME}`'s own
state bucket. Another project or CI environment in the same account may still
depend on the provider, and there is no cheap way to enumerate them — so the
script warns and names the account rather than pretending to know.
