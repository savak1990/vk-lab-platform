# Bootstrap stack

Creates Bootstrap-lifecycle resources that aren't the state bucket itself
(that's a separate, lower layer — see below). Currently just the `kms`
unit (the key for `secrets/*.enc`).

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

`make bootstrap-down` destroys `kms` (and any future bootstrap unit). It
does **not** touch the state bucket — that's `terraform/live/state`'s
resource, not this stack's, and there is no command that destroys it
(intentionally — see ADR 0004).
