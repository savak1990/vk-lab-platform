# ADR 0039: The project layer's region becomes an operator input

## Status

Accepted

Supersedes [ADR 0024](0024-single-fixed-aws-region.md) **for the project layer
only**. ADR 0024's rule stands unchanged for the account layer, and its
reasoning about derived declarations is preserved below rather than reversed.

## Context

ADR 0024 pinned the platform to one region, `eu-west-1`, and prohibited
deriving it from anything: "no `get_env` default, no `?=`, no workflow input,
no reliance on ambient `AWS_REGION`/`AWS_DEFAULT_REGION` or an operator's AWS
profile." It was right. Three arguments carried it: region portability did not
actually work, the mechanism was already decaying, and the platform was heading
off AWS.

Two of those three no longer describe the platform, and the third has inverted.

**The platform went off AWS, and the region became a capacity lever.** ADR 0024
argued that "paying ongoing complexity for a second *AWS* region, in a
disposable educational lab whose stated direction is away from AWS entirely, is
the wrong investment." The direction was correct: Civo (ADR 0027) and Hetzner
(ADR 0036) followed. But on Hetzner the location is not a preference, it is how
you get servers at all. HETZ-020 measured `cx33` unavailable in `fsn1` and
orderable in **both** `nbg1` and `hel1` on 2026-09-21, and `research.md:152`
concludes that a second location is a cheaper stock fallback than a second SKU.
ADR 0024 reasoned about AWS, where capacity is not the constraint, and its
2026-09-20 note then extended the no-derivation rule to `hcloud_location`
by analogy — an analogy that does not hold.

**The Hetzner server limit is per account, not per project.** Hetzner's
documentation says "Each customer has a default limit for the number of cloud
resources that we simultaneously provide" — customer. `HETZ-140:57` states "5
servers per project" and cites `research.md`, which does not say that. The
consequence is load-bearing: a second Hetzner project buys no extra capacity,
so a lab and a CI run share one pool of five and the split has to be chosen per
run rather than fixed in code.

**The failure ADR 0024 described was never fixed, only avoided.** ADR 0023
recorded that an SSM `SecureString` written in the project's region and
encrypted with `alias/lab-secrets` — which exists only in the account's region —
fails with `InvalidKeyId`. ADR 0024 closed that "by policy, not by fix," and
`AWS-031` costed the re-widening. This ADR fixes it.

## Decision

**`REGION` is the provider's region, and it is an operator input.**

For `PROVIDER=aws` that is the AWS region. For `civo` and `hetzner` it is that
cloud's own region or location, and **their AWS-side resources stay in
`eu-west-1` regardless** — a Civo project's state bucket, Route 53 zone, SSM
parameters and KMS usage do not move because its cluster is in Frankfurt.
`PROVIDER=local` owns no cloud resources, so it ignores the region rather than refusing it — these values are commonly left exported while switching targets.

**The account layer stays pinned to `eu-west-1`, permanently.** The shared
secrets KMS key, `lab-role`, the GitHub OIDC provider, `eks-access-identity`
and the account's own state bucket never move. This keeps one OIDC provider and
one shared role, which is what ADR 0021's account/project split is for.
`terraform/live/root.hcl` discriminates the region by layer exactly as it
already discriminates the state bucket. `scripts/lib/region.sh` gains
`LAB_ACCOUNT_REGION`, a constant that is never derived, while `LAB_REGION`
keeps its name and gains a provider-aware value — of its 84 uses across
`scripts/`, only 10 are account-scoped, so renaming the other 66 would have
been churn for its own sake.

**ADR 0024's actual property is preserved where it still applies.** The account
region remains a single literal declaration with no derivation. What changes is
that the *project* region is now a validated operator input rather than a
constant, and it reaches Terraform through one `get_env` per unit rather than
being recomputed anywhere.

**Validation is an offline allowlist, and it gates before any cloud call.**
`scripts/lib/catalog.sh` is keyed by (provider, region), because node-type
availability varies by region. It is also a cost guardrail: entries are few,
carry their price and date, and widening one is a reviewed change. A live API
probe was rejected — it needs credentials before validation can run, and
HETZ-020 proved Hetzner's own availability field unreliable in both directions.

**Bucket names carry the region.** `<project>-<region>-tf-state` and
`<project>-<region>-postgres-backups`. An S3 name is unique across every
account and region, so without this a region move is a delete-then-recreate
against a name AWS does not promise is immediately reusable. The region goes
*before* the existing suffix, so `lab-role`'s `arn:aws:s3:::*-tf-state` and
`arn:aws:s3:::*-postgres-backups` wildcards still match and no IAM change is
needed. The account layer's own bucket is unchanged.

**Changing `REGION` is guarded.** Terraform state is keyed by path, not region:
pointed at a new region it finds nothing, builds a second platform, and leaves
the first billing and invisible to state. The gate refuses a region change
while the project's state bucket holds resources, naming what to destroy first.

**The KMS blocker is fixed with a new multi-region key.** `alias/lab-secrets`
is single-region (verified: `MultiRegion: false`) and AWS does not allow
converting an existing key. A new multi-region key is created, replicated, and
given a per-region alias, so `alias/lab-secrets` resolves locally everywhere.
The constraint being solved is a *service* call, not KMS: a key is callable
from any region, but SSM encrypting on your behalf calls KMS in its own region.

**The `region` workflow input returns to `lab.yml`.** ADR 0024 deleted it
outright, arguing that "a one-option `type: choice` still presents region as an
operator knob; GitHub offers no read-only input." That argument was sound and
is now simply obsolete: it is no longer one option. It returns as a
`type: string` defaulting to blank, matching `project_name` and `subdomain`,
because GitHub has no dependent dropdowns and one flat list could not express
that `cx43` is valid in `nbg1` but not `hel1`.

**`AWS-031` is superseded.** It recorded what re-widening would cost so the
capability was deferred rather than lost. This is that work.

## Consequences

- **An AWS region other than `eu-west-1` is not selectable until the KMS
  migration lands.** The catalogue lists only `eu-west-1` for `aws` until then,
  so the gate refuses others in under a second. This is deliberate:
  `AWS-031` warns that "a partially-solved multi-region path is worse than
  none: it fails deep inside `persistent-up` on an SSM `SecureString` create
  rather than at validation time, which is precisely how the previous attempt
  decayed unnoticed." Civo and Hetzner regions are selectable immediately,
  because changing them moves no AWS resource.
- **Forking is still zero-source-change within the defaults.** Constitution §19
  is amended: a fork owner in another region now changes a catalogue entry
  rather than five constants, but the account region is still a source change.
- **A region move abandons retained EBS volumes.** They are availability-zone
  bound. `postgres_az` derives from the region and follows it, but the data does
  not. Accepted deliberately: a cluster started in a new region starts with
  fresh data. The S3/barman backup path is region-portable; the retired EBS
  snapshot path was not.
- **Service quotas and availability zones are per region and per account.** A
  region never used before starts at AWS defaults, and AWS maps AZ names to
  physical zones differently per account, so an `a` zone is not guaranteed to
  offer the chosen instance type. Neither is detected here; both fail at apply.
- **`make clusters` is incomplete under multi-region**, and is deferred. It is
  the only account-scoped tool, it takes no `PROJECT_NAME` by design, and it
  queries one region while its header promises every cluster in the account.
- **Three defects surfaced and are fixed:** `lab-role` hardcoded
  `arn:aws:rolesanywhere:eu-west-1:…`, a silent IAM denial for any project
  outside that region, named in neither ADR 0024 nor `AWS-031`; ADR 0024 and
  `AWS-031` both say "the two ESO-consumed passwords" when there are **three**
  `SecureString` parameters bound to the key; and `AWS-031` lists the ACM
  co-region constraint as a blocker when it is not one — the certificate is
  created in the same provider region as the NLB by construction, so
  constitution §14 is satisfied automatically when both move together.
- **ADR 0024's "five constants" was already four.** It lists `REGION` in the
  `Makefile` as one of the five floor declarations; no such variable exists
  there, and the Makefile only sources `scripts/lib/region.sh`.
- **ACM's lifecycle class is recorded inconsistently** and is corrected to
  Bootstrap, which is what the code does. `docs/architecture.md`, ADR 0002 and
  a comment in `gitops/values.yaml` all said Persistent. The certificate is
  DNS-validated against the delegated zone and is useless without it, and the
  zone is Bootstrap.
