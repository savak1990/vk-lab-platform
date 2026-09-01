# Bootstrap stack

Creates per-project Bootstrap-lifecycle resources: this project's own state
bucket, and the lab DNS zone/delegation (`route53`) + ACM certificate
(`acm`).

Account-global resources — the shared secrets KMS key, the shared `lab-role`
every project's GitHub Actions run assumes, the GitHub OIDC provider,
`eks-access-identity` — live in `terraform/live/account/` instead, applied by
`make account-up`. Everything here is per-project: each `PROJECT_NAME` gets
its own copy, in its own state bucket.

## No separate `state-up` step

`scripts/bootstrap-up.sh` creates this project's own state bucket itself,
first (the same `scripts/state-up.sh` two-phase local-then-migrate dance),
before generating/requiring `root-domain.enc` and applying `route53`/`acm` —
one command, no separate manual step. `make state-up`/`make state-down`
still exist as their own targets for manual/debugging use, but nothing in
the normal flow calls them directly anymore.

## Usage

```
make bootstrap-up      # this project's state bucket, then route53 + acm
make bootstrap-down    # guarded (CONFIRM_DESTROY=<PROJECT_NAME>) - see constitution §17
```

`make bootstrap-down` destroys `route53` and `acm` (and any future bootstrap
unit), then this project's own state bucket via raw AWS API (Terraform can't
destroy the bucket holding its own state — see ADR 0004). It does **not**
touch the shared account-global role/KMS key — those are `account-down`'s
job, affecting every project at once, not this project's own teardown.
`CONFIRM_DESTROY` must exactly equal `PROJECT_NAME`: the shared `lab-role`
has no per-project IAM scoping to fall back on the way the old
per-project role did, so this script-level check is the only guard.
