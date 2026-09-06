# 031 — Non-Home-Region Cluster Support (Deferred)

**Status:** Proposed — design only. ADR 0024 fixed the platform at a single
region; this document records what re-widening would actually cost, so the
capability is deferred rather than lost.

**Complexity:** High — not one hard problem. The blockers span KMS key topology,
the ACM/NLB co-region constraint, IAM ARN scoping, cross-region SSM reads, and an
availability-zone pin that retained EBS data depends on. Each must be solved before
a single cross-region cluster reaches Healthy.

**Risk:** Medium — nothing here is load-bearing today, so the risk is entirely in a
future implementation. A partially-solved multi-region path is worse than none: it
fails deep inside `persistent-up` on an SSM `SecureString` create rather than at
validation time, which is precisely how the previous attempt decayed unnoticed
(ADR 0024).

**Estimated cost:** nothing while deferred. Implementing adds a multi-region KMS
replica key (or a per-region key), a second ACM certificate per additional region,
and the data-transfer cost of any cross-region control-plane traffic. Engineering
cost is dominated by the verification, not the code: proving a retained-EBS restore
survives a region move needs a full lifecycle run per region.

**Recommended model:** Opus. The work is IAM and key-topology analysis across four
interacting AWS services, not mechanical edits.

**Depends on:** ADR 0024 (the decision this spec defers work from), ADR 0023 (the
`SecureString`/KMS co-region limitation this spec adopts), ADR 0021 (the
account-vs-project layer split that creates the two-region axis at all), spec 027
(the off-AWS direction that makes this low priority), constitution §14 (ACM
co-region with the NLB) and §19 as amended by ADR 0024.

**Lifecycle class(es) touched:** Bootstrap (the account layer's shared KMS key and
`lab-role` policy), Persistent (the ACM certificate, the Route 53 zone's SSM read,
and the `SecureString` parameters), and Disposable (the EKS cluster, its AZ pin and
its NLB). All three — which is itself a large part of why this is deferred.

## Motivation

The platform used to expose two independent region variables,
`ACCOUNT_MAIN_REGION` and `PROJECT_REGION`. Both always defaulted to `eu-west-1`,
the combination was never exercised, and it was already broken: ADR 0023 records
that `PROJECT_REGION != ACCOUNT_MAIN_REGION` fails at `persistent-up`. ADR 0024
deleted the configurability and pinned the platform to one region.

This spec exists so that removal is a deferral with a known price rather than an
undocumented loss. Anyone who later wants a cluster outside the account's home
region should find the blockers already enumerated, not rediscover them one failed
apply at a time.

## Scope

Supporting a disposable EKS cluster, and the project-scoped Persistent layer it
depends on, in an AWS region other than the account layer's home region — within a
single AWS account.

Excludes: multi-region high availability, active-active anything, cross-region
failover, multiple AWS accounts, and any relaxation of constitution §14's
requirement that the ACM certificate live in the same region as the NLB. Those are
separate decisions with their own cost arguments, and folding them in here is how
a bounded capability turns into a production-grade one nobody asked for
(`docs/architecture.md` lists production-grade multi-region availability as an
explicit non-goal).

## Findings

### The KMS key is single-region, and two credentials depend on it

`alias/lab-secrets` exists only in the account's home region. The two ESO-consumed
passwords (`/<project>/persistent/postgres/app_password` and
`/<project>/persistent/grafana/admin_password`) are SSM `SecureString` parameters
written in the project's region and encrypted with that key. AWS requires a
`SecureString`'s KMS key to be co-regional with the parameter, so those two creates
fail the moment the regions differ.

**This spec adopts ADR 0023's deferred limitation.** ADR 0024 closed it *by policy*
— the failure cannot occur when both regions are one value — not by fixing it. It
returns unchanged if this work is ever picked up, and it needs an owner in the
meantime.

Candidate fixes, both unevaluated: fall back to the region's own `alias/aws/ssm`
(cheaper, but changes the key-ownership story and the `kms:*` grant in
`terraform/modules/lab-role`), or create a multi-region KMS replica key (keeps one
logical key, adds per-region cost and a replication story). `scripts/secret-encrypt.sh`
and `scripts/secret-decrypt.sh` resolve the alias directly and would need the same
decision applied.

### The ACM certificate must be co-regional with the NLB

Constitution §14 requires it, and `docs/architecture.md` restates it. A cluster in
a new region therefore needs its own certificate *in that region*, validated by DNS
against the same delegated `lab.<root-domain>` zone. Route 53 is global, so the zone
itself is not a blocker — but the certificate is Persistent-lifecycle, so this means
a per-region certificate surviving `make down`, not one shared certificate. That has
a lifecycle-class consequence worth deciding deliberately: how many per-region
persistent certificates is a disposable lab willing to keep alive?

### The retained-EBS availability-zone pin is the real persistence hazard

`terraform/live/root.hcl` derives `postgres_az` as the region's `a` zone, consumed
by `terraform/live/cluster/eks` and `terraform/live/persistent/vpc`. That pin is
what makes retained Postgres volumes rebindable across `make down`/`make up`.

EBS volumes and snapshots are **availability-zone-bound, not region-bound**. Moving
a project to another region does not relocate its retained data — it orphans it.
`scripts/lib/persistent-ebs-artifacts.sh` and `scripts/argo-up.sh`'s snapshot
restore path both assume the volume is discoverable in the configured region.
Any implementation MUST define the data path explicitly: `ec2 copy-snapshot` into
the target region before the first apply there, or an accepted, documented loss.
Per CLAUDE.md, a PVC surviving logically is not evidence the EBS volume survived —
this needs an actual destroy/recreate proof in the target region, not an argument.

### `lab-role`'s region wildcards are load-bearing for this, and must stay

ADR 0024 considered narrowing `arn:aws:eks:*` and `arn:aws:ssm:*` in
`terraform/modules/lab-role` to `eu-west-1` and rejected it. That rejection happens
to be what keeps this capability cheap: the role already authorizes clusters in any
region. A future least-privilege pass MUST NOT narrow those ARNs without also
reading this spec, and MUST NOT reach for an account-wide
`StringNotEquals aws:RequestedRegion` Deny — that condition key is absent for
global services and the Deny would brick IAM, STS and Route 53 access.

### The cross-region data lookups were deleted, not disabled

`terraform/modules/route53-zone`'s SSM read of `/account/root_domain` and
`terraform/modules/external-secrets-pod-identity`'s KMS-alias read both lost their
explicit `region =` argument and now inherit the provider's. Restoring them means
restoring an account-region input to both modules, which means restoring the
two-region axis in `terraform/live/root.hcl` and `scripts/lib/region.sh` — i.e.
reversing ADR 0024's single-declaration rule across all five constants, not just
the two modules.

### Do not reintroduce SSM region self-discovery

`/account/main_account_region` was deleted by ADR 0024, and the mechanism that read
it had already been reverted before that. The reason is structural and still
applies: a parameter recording a region lives *in* that region, so querying it at a
guessed region returns `ParameterNotFound` — indistinguishable from "not written
yet," which silently confirms a wrong guess instead of catching it. Any revival must
carry the region explicitly, not discover it.

## Open Questions (block implementation, not this spec)

1. Multi-region KMS replica key, or per-region `alias/aws/ssm` fallback? The choice
   drives the `lab-role` `kms:*` grant, the `secret-encrypt`/`secret-decrypt`
   scripts, and the per-region cost.
2. Does the account layer stay pinned to one home region with only the project layer
   free, or do both move together? The former keeps one OIDC provider and one
   `lab-role` (both genuinely account-global and region-agnostic) but keeps every
   cross-region lookup; the latter removes the lookups and duplicates the account
   layer.
3. Is a per-region ACM certificate acceptable in the Persistent lifecycle class, or
   does it force a rethink of what Persistent means for a multi-region lab?
4. What happens to retained EBS data on a region move — copied, or explicitly
   abandoned? This is the only question with a data-loss answer.
5. Is a second AWS region ever actually wanted, given spec 027's off-AWS direction?
   If the honest answer is no, this spec should be closed rather than implemented.

## Recommendation

Do not implement. Revisit only if a concrete second-region requirement appears —
and when it does, re-open ADR 0024 and amend the constitution deliberately, per
constitution §13, rather than working around the single-region rule in code.
