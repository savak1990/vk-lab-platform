# Bootstrap stack

Creates per-project Bootstrap-lifecycle resources that aren't the state
bucket itself (that's a separate, lower layer — see below): `kms` (the key for
`secrets/*.enc`) and `personal-lab-role` (the hand-enumerated GitHub OIDC role
`lab-up.yml`/`lab-down.yml` assume — ADR 0022).

Account-global Bootstrap resources — the GitHub OIDC provider, of which
exactly one may exist per AWS account — live in `terraform/live/account/`
instead, applied by `make account-up`. Everything here is per-project: each
`PROJECT_NAME` gets its own copy, in its own state bucket (ADR 0021).

## Prerequisite: the `state` layer must already exist

`terraform/live/state/` (one level below `bootstrap/`, see
`docs/adr/0004-dedicated-state-lifecycle-layer.md`) creates the Terraform
state bucket every unit in this repository — including this one — stores
its state in. Run `make state-up` once, first, before anything under
`terraform/live/bootstrap/` can be applied. There is no chicken-and-egg
problem here anymore: by the time you apply `kms`, the bucket already
exists, so it uses the normal inherited S3 backend from the start.

## Usage

```
make bootstrap-up      # applies every unit under terraform/live/bootstrap/
make bootstrap-down    # guarded, rarely-used - see constitution §17
```

`make bootstrap-down` destroys `kms` and `personal-lab-role` (and any future
bootstrap unit) — destroying `personal-lab-role` breaks `lab-up.yml`/
`lab-down.yml`'s GitHub Actions auth for this project until it's re-applied.
It does **not** touch the state bucket — that's `terraform/live/state`'s
resource, not this stack's, and there is no command that destroys it
(intentionally — see ADR 0004).
