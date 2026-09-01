# State layer

Creates the Terraform remote-state S3 bucket every other project-scoped unit
in this repository (`state` itself, `bootstrap/*`, `persistent/*`,
`disposable/*`, `ci/persistent`, `ci/disposable`) stores its state in. See
`docs/adr/0004-dedicated-state-lifecycle-layer.md` for why this is its own
layer below Bootstrap rather than a unit inside it.

The Account layer (`terraform/live/account/`) has its own, separate
dedicated state bucket instead — see `terraform/live/account-state/` — never
this one, so a project's own state bucket can be destroyed without ever
touching the account-global role/KMS key's Terraform state.

## Usage

`scripts/bootstrap-up.sh` calls `scripts/state-up.sh` as its first step —
there's no separate manual invocation in the normal flow. The targets below
still exist for manual/debugging use:

```
make state-up
```

Runs `scripts/state-up.sh`. Idempotent: safe to run again later (applies
normally if the bucket already exists) — it only does anything special the
very first time, when the bucket doesn't exist yet and this unit's own
state has nowhere else to live.

```
make state-down
```

Runs `scripts/state-down.sh`. Refuses if Bootstrap, Persistent, Disposable,
or CI state still exists in the bucket. Essentially never run directly —
`scripts/bootstrap-down.sh` calls it as its own final step instead, after
`CONFIRM_DESTROY` has already gated the whole run. See ADR 0004 (why the
bucket is its own layer) and ADR 0005 (why a guarded destroy exists at all,
despite ADR 0004's original "no destroy command" decision). Bypasses
Terraform entirely: purges every object version and delete marker (the
bucket is versioned, so a plain delete only adds markers), then deletes the
bucket — this is the fix for the self-reference problem Terraform can't
solve on its own (it can't cleanly destroy the bucket holding its own
state).

To fully tear down and recreate everything from scratch (throwaway/test
AWS accounts only):

```bash
CONFIRM_DESTROY=$PROJECT_NAME make bootstrap-down   # zone + cert, then the state bucket itself
make bootstrap-up                                   # state bucket, then zone + cert
make secret-encrypt NAME=test VALUE=hello-from-spec-001
make secret-decrypt NAME=test
```
