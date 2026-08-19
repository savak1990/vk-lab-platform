# ADR 0005: A guarded `make state-down`, amending ADR 0004

## Status

Accepted (amends ADR 0004)

## Context

ADR 0004 created the State layer specifically to avoid the destroy-order
paradox of a bucket destroying itself while holding its own final state
write — and made "no destroy command at all" the load-bearing part of that
decision, on the theory that the only way to guarantee the paradox never
recurs is to never expose a destroy path.

In practice, a full teardown-and-recreate test of this repository's own
tooling still needed to destroy the bucket sometimes — for a throwaway/test
AWS account, or to fully retire the personal lab. Doing this by hand each
time (list every object version, purge delete markers, delete the bucket)
is exactly the kind of undocumented, error-prone manual step this
repository's tooling otherwise avoids for every other lifecycle class.

## Decision

Add `make state-down` (`scripts/state-down.sh`), matching the shape of
`make bootstrap-down`:

- Bypasses Terraform/Terragrunt entirely — plain `aws s3api` calls. This is
  what actually avoids ADR 0004's destroy-order paradox: there is no
  Terraform state write to fail, because Terraform is never involved in
  destroying this bucket.
- Guarded: refuses if Bootstrap, Persistent, Disposable, or CI state still
  exists in the bucket (same S3-prefix-existence check pattern as
  `bootstrap-down`, extended one layer further down).
- Requires typing the bucket name to confirm, same as `bootstrap-down`
  requires typing the stack name.
- Still expected to run essentially never — this does not change the
  State layer's place in the lifecycle (constitution §3), only removes the
  need for undocumented manual S3 surgery on the rare occasion it's needed.

## Consequences

- ADR 0004's "no destroy command at all" clause is superseded by this ADR.
  The rest of ADR 0004 (why the bucket is its own layer, the two-phase
  `state-up` bootstrap, the tag/key-prefix conventions) is unaffected.
- The full teardown-and-recreate test is now just a sequence of `make`
  targets, documented in `terraform/live/state/README.md`.
- This does **not** introduce a mechanism for tearing down per-environment
  or per-CI-run state. Ephemeral GitHub Actions environments (spec 015/019)
  are expected to use their own key prefixes (`ci/persistent/`,
  `ci/disposable/`) inside the same, still-shared, never-normally-destroyed
  bucket — not spin up or tear down the bucket itself. `state-down` remains
  a whole-account escape hatch, not part of any per-run lifecycle.
- `make status` (a `make bootstrap-up` prerequisite) reports which
  lifecycle layers currently have state in the bucket and fails only if
  the State layer itself is missing — it does not invoke `state-up`
  automatically, since constitution §17 forbids a command implicitly
  creating a different lifecycle class's resources.
