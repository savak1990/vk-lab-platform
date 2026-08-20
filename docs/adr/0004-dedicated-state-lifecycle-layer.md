# ADR 0004: A dedicated, never-destroyed "State" layer below Bootstrap

## Status

Accepted

## Context

Spec 001 (bootstrap) originally created the Terraform remote-state S3
bucket as a unit inside the Bootstrap-lifecycle stack, alongside the
secrets KMS key, with `make bootstrap-up`/`make bootstrap-down` managing
both together.

This has a structural problem `make bootstrap-down` cannot cleanly resolve:
the bucket holds its own Terraform state. On destroy, Terraform destroys
the bucket's AWS resources and then tries to write the final (empty) state
back to that same bucket — which no longer exists by that point. The
destroy itself succeeds in AWS, but the last state write errors, leaving a
confusing, "did this actually work?" result every single time this
resource is destroyed.

Three fixes were considered:

**a) Keep this unit's own state local forever, permanently, never migrated
to S3.** Solves the destroy-order paradox (a local backend has no
self-reference problem) but leaves the bucket-creation unit awkwardly
mixed in with the rest of Bootstrap, which *is* routinely destroyed via
`make bootstrap-down` — an inconsistency between "this one unit behaves
completely differently for lifecycle purposes" living inside a stack whose
other units don't.

**b) Automate the local-backend → migrate dance transparently in the
Makefile, keeping it inside Bootstrap.** Keeps this unit's state remote
like every other stack, but only automates *creation*; the destroy-order
paradox is still real and still fires every time `bootstrap-down` runs,
now hidden behind tooling instead of removed.

**c) Provision the bucket outside Terraform entirely** (a one-off
`aws s3api create-bucket` script), optionally `terraform import`ed later
for drift detection only, never destroyed via Terraform. Fully avoids the
problem, but breaks this platform's "Terraform/Terragrunt owns AWS
infrastructure" consistency (constitution §2) for one particular resource,
without a strong enough reason to justify a special case.

## Decision

Split the state bucket out of Bootstrap entirely, into its own layer,
**State**, one level below Bootstrap:

```
State (new, this ADR)
  ↓ created once, never destroyed by any command in this repository
Bootstrap
  ↓ created once, rarely destroyed (constitution §3)
Persistent
  ↓ survives make down
Disposable
  ↓ make up / make down
```

- `terraform/live/state/` is its own Terragrunt unit, using the same
  `terraform/modules/terraform-state` module Bootstrap used to use
  directly.
- `make state-up` (running `scripts/state-up.sh`) creates it. The script
  handles this unit's own first-run chicken-and-egg problem (temporary
  local-backend override → apply → restore → `init -migrate-state`) so
  the committed `terragrunt.hcl` never needs manual editing.
- **There is no `state-down`, at all.** ~~This is the load-bearing part of
  the decision~~ — **amended by ADR 0005**, which adds a guarded
  `make state-down`. The destroy-order paradox this ADR exists to fix is
  avoided because destroy bypasses Terraform entirely (plain S3 API calls),
  not because no destroy path exists. See ADR 0005 for the guard and the
  reason a destroy path turned out to be needed after all.
- `Lifecycle = state` is a new tag value, alongside `bootstrap | persistent
  | disposable` (constitution §16's tag enum, architecture.md §39). It's
  derived automatically from the unit's path under `terraform/live/`
  (`terraform/live/root.hcl`'s `local.lifecycle_class`), the same
  mechanism that already derives `bootstrap`/`persistent`/`disposable` —
  no special-casing needed in `root.hcl` itself.
- `make bootstrap-up`/`make bootstrap-down` now only manage the `kms` unit
  (Bootstrap's remaining Terraform-owned resource until spec 014 adds
  `github-oidc/` alongside it — see spec 001's scope amendment).

## Consequences

- `make bootstrap-down` (constitution §17's guarded, rarely-used escape
  hatch) is now genuinely simpler: it destroys the KMS key and nothing
  else touches the bucket. Its guard checks (refuse if Persistent/
  Disposable state exists) are unaffected — they were never about the
  State layer to begin with.
- Every later spec's `remote_state` configuration continues to point at
  the same bucket (`vk-lab-platform-tf-state`) and key-prefix convention
  (`bootstrap/`, `persistent/`, `disposable/`, `ci/persistent/`,
  `ci/disposable/`) as before — this ADR only moves *which unit manages
  the bucket resource itself*, not the bucket, its name, or its layout.
- Spec 001's scope shrinks again (after the earlier OIDC move to spec
  014): it now covers only the `kms` unit, tagging, and
  `make bootstrap-up`/`make bootstrap-down`. Creating the state bucket is
  a new, un-numbered prerequisite step (`make state-up`), documented in
  `terraform/live/state/README.md` and referenced from spec 001 rather
  than owned by it.
- A second AWS account (e.g. a disposable/throwaway test account for the
  full lifecycle test — spec 018) runs `make state-up` once as its own
  first step, exactly like the real personal-lab account did.
