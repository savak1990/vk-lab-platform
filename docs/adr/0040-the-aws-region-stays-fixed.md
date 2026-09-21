# ADR 0040: The AWS region stays fixed; `REGION` selects a Civo or Hetzner region only

## Status

Accepted

Withdraws [ADR 0039](0039-project-region-as-operator-input.md)'s supersession of
[ADR 0024](0024-single-fixed-aws-region.md). ADR 0024 stands unsuperseded and in
full. ADR 0039 is narrowed to the Civo and Hetzner targets, where its reasoning
holds and its implementation has shipped.

## Context

ADR 0039, accepted earlier the same day as this record, made the project layer's
region an operator input on every provider. For Civo and Hetzner that was right
and is in use: `REGION` selects the Civo region or the Hetzner location, their
AWS-side resources stay in `eu-west-1`, and state buckets namespace by the
provider's own region so two regions cannot share one state.

For AWS it was wrong, and it was never exercised. `scripts/lib/catalog.sh` has
only ever listed `eu-west-1` for `aws`. No multi-region KMS key was created, no
replica exists, no project ever applied outside `eu-west-1`. ADR 0039 deferred
the enabling work — a new multi-region key, replicated, with a per-region alias —
to a migration that has not run. Reversing the AWS arm therefore costs a
specification rewrite and nothing else.

### Why the AWS region is structural, not conventional

ADR 0024 named the blocker as one SSM/KMS co-region failure and ADR 0039 proposed
to fix it with a new key. Investigation for that migration found the coupling is
wider than either record states. Verified live against account `753939038916` on
2026-09-21:

**The secrets key is account-layer and single-region.** `alias/lab-secrets`
targets key `bc8ca7ef-63d3-4d08-b0e4-425c38e9bb9f`, `MultiRegion: false`, created
by `terraform/live/account/kms`. AWS cannot convert an existing key to
multi-region.

**Four project-scoped consumers need that key resolvable locally, not two.** ADR
0023, ADR 0024 and `AWS-031` all describe the blocker as "the two ESO-consumed
passwords". The real set is:

| # | Consumer | Location | Call made in the project's region |
|---|---|---|---|
| 1 | `data "aws_kms_secrets"` over the committed `.enc` files | `persistent-secrets/main.tf:1-10` | `Decrypt` against a blob bound to a `eu-west-1` key |
| 2 | `SecureString` parameters naming the alias | `persistent-secrets/main.tf:12-26` | SSM encrypts on your behalf, calling KMS locally |
| 3 | alias lookup | `external-secrets-pod-identity/main.tf:13-15` | `ListAliases` where the alias does not exist |
| 4 | alias lookup | `rolesanywhere/main.tf:4-6` | `ListAliases` where the alias does not exist |

A third `SecureString` exists outside Terraform, written by
`scripts/lib/provider.sh` when a Civo or Hetzner teardown exports the serving
certificate. It names the same alias.

**The role's own grant follows the alias at apply time.** `lab-role` reads
`data "aws_kms_alias" "secrets"` and builds both its `kms:*` grant and its
`DenySharedKmsKeyDestruction` Deny from `target_key_arn`
(`terraform/modules/lab-role/main.tf:393-403`). Any change to which key the alias
names silently leaves CI holding permissions on the previous key until the
account layer is applied again — an ordering requirement no record stated.

**The certificate cannot move independently.** Constitution §14 requires the ACM
certificate to live in the same region as the NLB that uses it, so a project in
another region needs its own certificate, and ADR 0002's delegated zone is a
single account-wide `lab.<root-domain>`.

None of this is unsolvable. All of it is ongoing complexity bought for a
capability with no demand, in a disposable educational lab whose stated direction
is away from AWS — the same argument ADR 0024 made, strengthened by measurement.

## Decision

**The AWS region is fixed at `eu-west-1`, for every layer and every lifecycle
class, permanently.** ADR 0024's rule is restored exactly as written, including
its prohibition on a derived declaration.

**`REGION` is not an input on the `aws` target and MUST be refused.** A value
other than `eu-west-1`, in any case, fails offline in
`scripts/lib/require-valid-node-config.sh` with a message that states the rule
rather than implying an unlisted option. The refusal is loud rather than silent
because a typed region is a statement of intent that the platform cannot honor;
this is the opposite of the `local` target, which owns no cloud resources and
ignores all three inputs.

`REGION=eu-west-1` is accepted. It is the one legal value, and refusing an
operator who names it correctly would punish a shell that still exports it from
an earlier command without protecting anything.

**`REGION` keeps its meaning on `civo` and `hetzner`,** validated against
`scripts/lib/catalog.sh`, matched case-insensitively and canonicalised to the
provider's own spelling. Their AWS-side resources stay in `eu-west-1`.

**The catalogue keeps `eu-west-1` in the `aws` region list rather than emptying
it.** `catalog_default_region`, the `aws:eu-west-1` node-type key and
`state-up.sh`'s region-change guard all read it. An empty list would break three
callers to express a rule the gate already enforces.

**`LAB_REGION` and `aws_region` stop branching.** Both can now only hold the
account region, so `scripts/lib/region.sh` and `terraform/live/root.hcl` assign
it unconditionally. `LAB_REGION` keeps its name at its 66 project-scoped call
sites: it still means "this project's AWS region", a meaningful concept that is
now constant, and renaming it would be churn with no behavior change.

**The `Makefile`'s `REGION ?= eu-west-1` stays, and is not the `?=` ADR 0024
prohibits.** That prohibition protected against *configurability* — a second site
able to select a different region. Removing this line would not remove the
default, only move it: `scripts/lib/provider.sh` already supplies
`catalog_default_region` for any unset input. With the gate refusing every other
value, the `?=` supplies the single legal value rather than offering a choice.

**The GitOps `--set region=` chain that ADR 0024 deleted is never restored.**
`gitops/values.yaml` keeps one literal `region: eu-west-1` for the AWS Load
Balancer Controller and the `ClusterSecretStore`. Its existing comment — "Fixed,
not an operator knob" — becomes permanently true.

**No KMS migration.** No multi-region key, no replicas, no re-encryption of the
committed ciphertext, no key retirement. `alias/lab-secrets` stays as it is.

## Consequences

- **`specs/aws/031-Z-non-home-region-cluster/` is permanently declined, not
  deferred with intent.** Its cost analysis stays valuable and stays accurate —
  it is now the record of a road not taken. It is not superseded by SHARED-044.
- **One project in two AWS regions is impossible by construction.** The
  equivalent question for Civo and Hetzner survives and is unresolved: their
  AWS-side names are not region-qualified, so `/vk-civo-lab/persistent/…` is one
  parameter path for every Civo region. That is a naming collision, not a region
  problem, and is tracked in SHARED-044.
- **Forking is zero-source-change within `eu-west-1`,** exactly as ADR 0024
  states. Constitution §19 is amended back to say so for the AWS axis while
  keeping `REGION` documented for the other two providers.
- **ADR 0039 is not withdrawn.** Its account/project split, its `REGION`
  validation and its region-namespaced state buckets all shipped and all stand.
  Only its AWS arm and its claim over ADR 0024 are withdrawn.
- **ADR 0039's supersession of ADR 0024 was too broad in kind, not only in
  scope.** ADR 0024 was only ever about the AWS region; Civo and Hetzner regions
  were never within it. There was nothing for ADR 0039 to supersede.
- **The blocking analysis in ADR 0039 and SHARED-044 §3.6 was incomplete.** Both
  state that only the SSM consumer blocks. All four block, as the table above
  records. This strengthens the present decision; it changed nothing while the
  capability was unused.
- **`CLAUDE.md`'s region paragraph becomes correct again.** It was never updated
  for ADR 0039 and had been wrong since that record merged.
- The gate is now covered by `tests/scripts/node-config-test.sh` and
  `make node-config-check`, so the rule is regression-tested rather than resting
  on a manual matrix.
- **No live infrastructure changes.** Every rendered Terraform value, every
  bucket name and every `make -n` line is byte-identical to before this decision,
  because `REGION` could only ever hold `eu-west-1` on `aws` in practice.
