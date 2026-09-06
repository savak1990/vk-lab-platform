# ADR 0026: On-demand full-lifecycle CI workflow

## Status

Accepted

## Context

Spec 020 (CI Full Lifecycle Validation) specifies a full-up/test/full-down
workflow against isolated `terraform/live/ci/{persistent,cluster}` state, its
own IAM role, and its own `ci.lab.<root-domain>` DNS zone/certificate. None of
that exists yet - `.github/workflows/` contains only `lab.yml`.

Building `terraform/live/ci/` as spec 020 describes it means: a second
Terraform state hierarchy, a new IAM role and trust policy, and a new
delegated DNS zone/certificate - real infrastructure, days of work, before the
workflow can run at all.

`lab.yml` already provides everything spec 020's isolation requirement is
actually for. Isolation is achieved today by `PROJECT_NAME`/`SUBDOMAIN`, not by
a separate state tree: `scripts/require-unique-subdomain.sh` refuses to let
two projects share a subdomain, `lab-role`'s permission policy scopes by
naming convention (`*-eks`, `*-tf-state`) rather than by an enumerated
project list (ADR 0022), and a distinct `PROJECT_NAME` gets a wholly separate
cluster, state bucket, and DNS zone with zero IAM changes.

Three further decisions came up in the same design pass and are recorded here
together since they define one workflow.

## Decision

### 1. Reuse `PROJECT_NAME`/`SUBDOMAIN` isolation instead of `terraform/live/ci/`

The new `lifecycle-test.yml` workflow runs `make full-up` -> `make test` ->
`make full-down` against a dedicated `PROJECT_NAME` (default `vk-lab-ci`) and
`SUBDOMAIN` (default `ci`), using the exact same `lab-role` OIDC role as
`lab.yml`. This is a deliberate deviation from spec 020 Requirement 2's
literal "own IAM role, own `terraform/live/ci/` state" design (constitution
§13 requires such a deviation be documented, not silently substituted).

The workflow's concurrency group (`lab-${{ inputs.project_name }}`) matches
`lab.yml`'s expression exactly, so a run against the same `PROJECT_NAME` from
either workflow queues rather than races the same S3 state.

Spec 020's other requirements are still honored: disposable resources still
carry the standard tags (constitution §16), the run still uses its own
subdomain/certificate (via the normal bootstrap-up path, not a shared one),
untrusted PRs still cannot trigger it (`workflow_dispatch` only), and a
failed run still attempts cleanup (`down` job, `if: always()`).

Deferred, not addressed by this ADR: spec 020's `Ephemeral=true` tag, the
scheduled stale-resource reaper (spec 020 Requirement 8), and an AWS Budgets
alarm. None of the three exist anywhere in the repo today.

### 2. The post-destroy leak sweep deletes, then still fails

ADR 0012 held that a sweep finding leftover resources after a teardown "is a
sign the cascade didn't actually finish, which should surface as a failure,
not be silently absorbed" - and accordingly `cluster-down.sh`'s existing
sweep only warned, never deleted.

That leaves a leaked resource billing for as long as it takes a human to
notice the warning. This ADR amends ADR 0012: `cluster-down.sh`'s sweep now
deletes every leaked resource it finds (widened to cover ENIs, load-balancer
security groups, Karpenter launch templates, and orphaned Karpenter instance
profiles, in addition to the instances/volumes/NLBs it already checked) and
still exits non-zero if it found anything. The underlying cascade bug still
surfaces as a failed run; it no longer costs money while it waits to be
noticed.

EBS snapshots are deliberately excluded from this sweep - they are the
Postgres recovery artifact ADR 0013 depends on, and belong to
`persistent-down.sh`'s own cleanup at its own point in the lifecycle.

This also fixes a latent bug: `resourcegroupstaggingapi:GetResources` had no
IAM grant in `lab-role` at all, so the existing NLB/target-group leak check's
failure was silently swallowed by the script's own `|| true` - it has never
actually run. `terraform/modules/lab-role/main.tf` now grants
`tag:GetResources`, plus `iam:ListInstanceProfiles`/`iam:GetInstanceProfile`
scoped to Karpenter's instance-profile path, needed to discover an orphaned
profile before deleting it.

### 3. `FIXED_TEST_PASSWORDS=true` in this workflow

`generate-secrets.sh` already supports this via the `FIXED_TEST_PASSWORDS`
environment variable (default `false`); `lifecycle-test.yml` sets it at the
workflow level so every run gets known credentials (`test`) rather than
per-run random ones.

Accepted exposure: for the run's ~1.5-hour lifetime, ArgoCD and Grafana
(cluster-admin and platform-admin respectively) are reachable over public
HTTPS at `argo.<subdomain>.<root-domain>` / `grafana.<subdomain>.<root-domain>`
with a publicly known password. This is judged acceptable because the
environment is short-lived, holds only synthetic CI data, and is destroyed at
the end of every run - but it is a real exposure, not a hygiene-only concern,
and should not be copied into any longer-lived environment without
reconsidering it.

## Consequences

- `lifecycle-test.yml` can be dispatched today with no new Terraform.
- A colliding `PROJECT_NAME` between a personal-lab run and a CI run is
  possible in principle (nothing prevents someone from typing
  `vk-lab-platform` into `lifecycle-test.yml`'s input) - guarded only by the
  workflow's default value and operator discipline, not IAM. Moving to
  spec 020's separate `terraform/live/ci/` tree later would close this gap
  structurally; this ADR does not close it.
- `full-down` destroys the Route 53 zone, ACM certificate, and state bucket
  every run. A run that dies between zone-creation and state-write leaves
  `scripts/require-unique-subdomain.sh` refusing every later run against that
  `PROJECT_NAME`/`SUBDOMAIN` pair until cleaned up by hand. The `down` job's
  `if: always()` and each job's 120-minute timeout narrow this to the
  hard-cancellation case, not eliminate it.
- Any new ADR must be numbered 0027 or later - `specs/civo/015-governance-adrs-constitution/spec.md`
  still plans to claim 0025-0029, which this ADR (0026) and ADR 0025 (already
  Accepted) have both preempted; that spec's ADR numbers need renumbering
  before those Civo ADRs are written.

## Related

- ADR 0012 (amended by this ADR's decision 2)
- ADR 0013 (why EBS snapshots are excluded from the sweep)
- ADR 0014 (why fixed passwords matter for password-sensitive recovery paths)
- ADR 0022 (naming-convention IAM scoping this ADR's isolation choice relies on)
- `specs/020-ci-full-lifecycle-validation/spec.md` (the design this ADR
  deviates from, per constitution §13)
- `specs/014-lifecycle/spec.md` Requirement 5 (pre-authorizes exactly this
  class of postcondition-verification script)
