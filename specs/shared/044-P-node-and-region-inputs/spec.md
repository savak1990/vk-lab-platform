---
id: "SHARED-044"
title: "NODE_COUNT, NODE_TYPE and REGION as validated operator inputs on every provider"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "A KMS key migration over committed ciphertext, a two-axis region split across ~95 call sites, and a guard whose failure mode is a silently doubled cloud bill"
effort_estimate: "Three sessions, one per pull request; the third needs a real apply in a second AWS region"
estimate_confidence: "low"
depends_on: []
blocked_by: []
supersedes: ["AWS-031"]
created: "2026-09-21"
updated: "2026-09-21"
completed: ""
---

# SHARED-044 — node count, node type and region as operator inputs

## 1. Outcome and rationale

The shape of a cluster becomes an operator input, validated offline, uniform
across providers:

```sh
PROVIDER=hetzner NODE_COUNT=3 NODE_TYPE=cx33            REGION=nbg1      make up
PROVIDER=civo    NODE_COUNT=3 NODE_TYPE=g4s.kube.medium REGION=LON1      make up
PROVIDER=aws     NODE_COUNT=1 NODE_TYPE=t4g.medium      REGION=eu-west-1 make up
```

Every default reproduces today's behaviour exactly, so an unset variable
changes nothing.

Today those three values are literals spread across `terraform/live/root.hcl`,
`scripts/lib/region.sh`, the Terraform modules and `gitops/values.yaml`.
Changing one means editing code, and nothing refuses a Hetzner location handed
to the AWS provider.

Two findings forced this.

**The Hetzner server limit is per account, not per project.** Hetzner's own
FAQ says *"Each customer has a default limit for the number of cloud resources
that we simultaneously provide"* — customer, not project. `HETZ-140:57` states
"5 servers per project" and cites `research.md`, which does not say that. The
consequence is load-bearing: a second Hetzner project buys **no** extra
capacity, so the lab and CI share one pool of five and the split has to be
chosen per run. `NODE_COUNT` is how it gets chosen — 3 for the lab, 2 for CI.

**Location is a stock lever on Hetzner.** HETZ-020 measured `cx33` unavailable
in `fsn1` but orderable in **both** `nbg1` and `hel1` (`research.md:144`), and
`research.md:152` concludes a second location is a cheaper fallback than a
second SKU. ADR 0024 pinned the region when AWS was the only target and a
region move meant a broken KMS dependency; it never contemplated a provider
where the location is how you get capacity at all.

## 2. Scope and non-goals

In scope: `NODE_COUNT`, `NODE_TYPE` and `REGION` as operator inputs on `aws`,
`civo` and `hetzner`; a per-provider allowlist and the gate that enforces it;
the account/project region split; the KMS key migration that unblocks it; the
`README.md` command and variable reference; ADR 0039 and the constitution §19
amendment that authorise it.

Not in scope:

- **The account layer's region.** It stays `eu-west-1` permanently. Only the
  project layer moves. This keeps one OIDC provider, one `lab-role` and one
  logical secrets key.
- **`make clusters` under multi-region** — deferred by operator decision, see
  §5.1.
- **Karpenter's instance list** (`gitops/values.yaml:106,110`). It carries the
  same region-availability constraint and is not governed by the catalogue.
- **Right-sizing pod requests.** That is CIVO-175 and HETZ-175's other half.
- **Migrating existing data on a region change.** Retained EBS volumes are
  availability-zone-bound; a region move abandons them. Accepted by the
  operator: a cluster started in a new region starts with fresh data.

**Rejected: a live API probe for validation.** Querying each cloud's real
catalogue is always accurate, but it needs credentials and network *before*
validation can happen, adds latency to every command, and HETZ-020 proved
Hetzner's own availability field unreliable in both directions
(`research.md:21`). Correctness and stock are different questions; this spec
answers the first, offline. HETZ-175's pre-flight probe answers the second.

**Rejected: duplicating the allowlist into Terraform.** ADR 0024's reasoning
holds — generating one language's constants from another is more machinery
than this repository warrants. The shell gate runs first and is the
enforcement point; Terraform keeps only narrow `validation` blocks.

## 3. Requirements

### 3.1 The catalogue

`scripts/lib/catalog.sh` (new) is the single source of truth for the shell
side. It is keyed by **(provider, region)**, not by two independent lists:
node-type availability varies by region, so flat lists would accept
combinations that cannot be created.

| Provider | Region | Node types allowed there |
|---|---|---|
| `aws` | `eu-west-1` *(default, and the only one until §3.6 lands)* | `t4g.medium` *(default)*, `t4g.large`, `m6g.large` |
| `civo` | `LON1` *(default)*, `NYC1`, `FRA1`, `MUM1` | `g4s.kube.medium` *(default)* |
| `hetzner` | `nbg1` *(default)* | `cx23`, `cx33` *(default)*, `cx43` |
| `hetzner` | `hel1` | `cx23`, `cx33` — **not** `cx43` |
| `hetzner` | `fsn1` | none orderable as of 2026-09-21 |
| `local` | — | ignores all three inputs |

Default `NODE_COUNT`: `aws` 1, `civo` 3, `hetzner` 3.

Civo's regions are `civo region ls` on 2026-09-21. The CLI answers them
lowercase while the platform has always passed `LON1`, so operator input is
matched case-insensitively and canonicalised to the spelling above, which is
what reaches a CLI and Terraform. There is no `PHX1`; `MUM1` exists.

The Hetzner rows are HETZ-020's measurement (`research.md:144`), not a copy of
Hetzner's catalogue. `fsn1` listing nothing is deliberate — the gate refuses it
with the measurement date rather than letting Terraform fail on placement.

**The lists are a cost guardrail, not a mirror of each cloud.** Ceilings are
per provider, because the clouds are not comparable: €25 buys a real range on
Hetzner, while on AWS nothing under $27 has more than 4 GiB.

| Provider | Ceiling | Evidence |
|---|---|---|
| `hetzner` | €25 | `cx43` (8 vCPU/16 GiB) fits at €22.37 |
| `civo` | $27 | `g4s.kube.medium` $21.73; `Large` $43.45 is out |
| `aws` | ~$63 | `t4g.medium` $26.86 is the only option under $27 |

Every entry MUST carry its price, the date and the source as a comment. A cost
ceiling nobody can audit is not a guardrail.

`m6g.large` ($62.78) costs 17% more than `t4g.large` ($53.73) for identical
specs and is present for exactly one reason: `t4g` is burstable and throttles
to 20% baseline once CPU credits are exhausted, while `m6g` does not. No
credit-exhaustion incident is recorded anywhere in this repository, so it is
insurance and never the default. **That rationale MUST be in the comment**, or
a later reader deletes the entry as obviously poor value.

Excluded on evidence: `t4g.small` by a hard constraint rather than price —
`specs/aws/028:22` records 17 pods per node on `t4g.medium` (3 ENIs × 6 IPs),
and fewer ENIs cannot hold the platform's pod count; `m6g.medium`,
`m7g.medium` and `m8g.medium` because all are 1 vCPU and dearer per GiB than
`t4g.medium`.

### 3.2 The gate

`scripts/lib/require-valid-node-config.sh` (new) mirrors
`scripts/lib/require-valid-project-name.sh` exactly: a library exposing a
function, not a standalone script, invoked by a `.PHONY` target in the
`Makefile:260-261` idiom. Every lifecycle target gains it as a prerequisite,
as `up`, `down` and `full-up` already depend on `require-valid-project-name`.

It MUST fail before any cloud call and MUST need no credentials. It MUST name
what is legal:

```
Refusing: invalid node configuration for PROVIDER=aws
  - REGION 'nbg1' is not valid for PROVIDER 'aws'

  aws     : eu-west-1
  civo    : LON1 NYC1 FRA1 MUM1
  hetzner : nbg1 hel1 fsn1
```

On `PROVIDER=local` it MUST **ignore** all three rather than refuse them.
`local` is one kind cluster on the operator's machine
(`scripts/cluster-up-local.sh`), reaches no cloud API and has neither a region
nor a cloud node type, so there is nothing for them to describe. They are
commonly left exported in a shell while switching targets, and refusing would
make `PROVIDER=local make up` fail over values it does not read.
`scripts/lib/region.sh` discards them the same way.

`NODE_COUNT` being a positive integer is additionally checked in the Makefile
itself, in the existing `Makefile:9-12` idiom, so a typo fails before any
script runs.

### 3.3 What `NODE_COUNT` counts

**Every node the operator pays for in the fixed pool.** Autoscaler and
Karpenter capacity is added on top and is not counted.

| Provider | Interpretation |
|---|---|
| `aws` | `eks_managed_node_groups.system` min/max/desired (`eks/main.tf:129-131`), today 1. Karpenter supplies workload capacity. |
| `civo` | `pools[0].node_count` (`civo-k8s/main.tf:29`), today 3, already under `ignore_changes` for the autoscaler. |
| `hetzner` | 1 control plane + (`NODE_COUNT` − 1) workers. The control plane is schedulable by decision (`decisions.md:46`) and is billed, so it counts. |

On Hetzner this makes the variable mean the same thing as the account limit
counts, which is the number the operator has to reason about.

### 3.4 Terraform

Each value becomes a module variable with the same default, so a bare
`terragrunt apply` is unchanged. Units pass them with
`inputs = { node_count = get_env("NODE_COUNT", "<default>") }`.

Terraform keeps only narrow `validation` blocks: `node_count > 0`, and
HETZ-030's existing `control_plane_count == 1` lock.

### 3.5 The region split

`terraform/live/root.hcl:34` already discriminates the state **bucket** by
layer. The region MUST gain the same shape, so account-scoped units render
`eu-west-1` whatever `REGION` says:

```hcl
aws_region = contains(["account", "account-state"], local.raw_class)
  ? local.account_region : local.project_region
```

**`REGION` means the provider's region.** On `aws` it is the AWS region; on
`civo` and `hetzner` it is that cloud's own region or location and their
AWS-side resources stay in the account region regardless; `local` accepts none.
So `aws_region` is account-region unless the target is `aws`:

```hcl
aws_region = (contains(["account", "account-state"], local.raw_class)
  || local.provider_name != "aws"
  || local.region_input == "") ? local.account_region : local.region_input
```

`scripts/lib/region.sh` gains `LAB_ACCOUNT_REGION` — a constant, never derived —
and **`LAB_REGION` keeps its name** while gaining a provider-aware value.
Measured on this branch: of 84 `LAB_REGION` occurrences in `scripts/`, only
**10 are account-scoped**, in four files — `account-state-down.sh` (7),
`account-state-up.sh` (1), `secret-encrypt.sh` (1), `secret-decrypt.sh` (1).
Those move to `LAB_ACCOUNT_REGION`; the other 66 need no edit. Renaming the
common case would be churn for its own sake.

Two sites MUST NOT be changed by a mechanical pass:

- **`account-down.sh:32,38`** look account-scoped from the file name but are
  project-scoped: they drive the guard that refuses to tear down the account
  layer while a project still holds state. Pointed at the account region, that
  guard silently finds nothing for a project elsewhere and `account-down`
  proceeds.
- **`cluster-down.sh:196`** is not a `--region` flag. It interpolates the
  region into an IAM path Karpenter mints,
  `--path-prefix "/karpenter/$LAB_REGION/$CLUSTER_NAME/"`. IAM is global, so
  treating it as inert is wrong; it must follow the project region.

`gitops/values.yaml:7` needs the `--set region=` chain ADR 0024 deleted
restored in three places: `scripts/argo-up.sh`, `gitops/bootstrap/values.yaml`
and `gitops/bootstrap/templates/root-application.yaml`. Six golden files bake
the literal.

**That restoration belongs with the KMS migration, not with the region
split.** The value feeds the AWS Load Balancer Controller and the
`ClusterSecretStore`, both of which read AWS in the *project's AWS region* —
which is `eu-west-1` for every provider until the AWS catalogue widens.
Restoring the chain earlier would add a knob that can only ever be set to the
value it already has, and six golden files would churn for no behaviour
change.

**AWS keeps one region until §3.6 lands.** The catalogue lists only
`eu-west-1` for `aws`, so the gate refuses any other in a second rather than
letting it fail deep inside `persistent-up`. `AWS-031` warns exactly against
the alternative: "a partially-solved multi-region path is worse than none: it
fails deep inside `persistent-up` on an SSM `SecureString` create rather than
at validation time, which is precisely how the previous attempt decayed
unnoticed." Civo and Hetzner regions open immediately, because changing them
moves no AWS resource.

### 3.6 The KMS migration

`alias/lab-secrets` is account-layer, `eu-west-1`, and single-region —
verified live: `MultiRegion: false`, key id `bc8ca7ef-…`, a plain UUID rather
than the `mrk-` prefix a multi-region key carries. AWS does not allow
converting an existing key, so this needs a new one.

Four project-scoped consumers depend on it:

| # | Consumer | Location |
|---|---|---|
| 1 | `data "aws_kms_secrets"` decrypting the committed `.enc` files | `persistent-secrets/main.tf:1-10` |
| 2 | three `SecureString` parameters with `key_id` | `persistent-secrets/main.tf:12-26`, `lib/provider.sh:376` |
| 3 | alias read | `external-secrets-pod-identity/main.tf:13-15` |
| 4 | alias read | `rolesanywhere/main.tf:4-6` |

**The constraint is a service call, not KMS.** A KMS key is regional but its
API is callable from any region, and this key's policy is the AWS default
(`…:root` / `kms:*`), so IAM alone governs. What cannot cross a region is
another service encrypting on your behalf: SSM in one region calls KMS in that
region. That is why #2 blocks and #1, #3 and #4 do not.

Note both ADR 0024 and AWS-031 say "the two ESO-consumed passwords". **There
are three** — the third is the TLS Secret export at `lib/provider.sh:376`,
which holds a private key. Consumer #1 is documented in neither, despite being
the first thing that fails.

**The fix is one new multi-region key, replicated, with a per-region alias.**
Aliases are regional, so `alias/lab-secrets` exists in every region and
resolves to that region's replica. All four consumers are then satisfied
locally and no aliased provider is needed anywhere.

The migration MUST run in this order, so every step before the last is
reversible:

1. `terraform/modules/kms` gains a `multi_region` variable. Create the new key
   in the account layer under a temporary alias `lab-secrets-next`, following
   the repository's existing `ROTATE=1` → `*-next` convention.
2. Replicate into every region in the catalogue's `aws` list, each with its own
   `alias/lab-secrets-next`.
3. Re-encrypt the 12 committed `.enc` files against the new key. Decrypt needs
   no key id — KMS reads it from the ciphertext — so this pipes
   `secret-decrypt.sh` into `secret-encrypt.sh` and plaintext never reaches
   disk.
4. **Verify all 12 round-trip against the new key before anything is removed.**
   This is the gate. The old key is still intact here.
5. Repoint `alias/lab-secrets` to the new key in every region. No code changes:
   every consumer already names the alias. The three `SecureString` parameters
   re-encrypt in place on the next apply, because their plaintext is
   re-supplied from the `.enc` files.
6. Retire the `-next` aliases.
7. Prove it: a full `up` → `test` → `down` on **both** AWS and Civo.
8. **Only then** schedule the old key for deletion, at the maximum 30-day
   window. It costs about 1 USD/month and is the rollback until it dies.

During steps 3 to 5 mixed ciphertext works, because decrypt resolves the key
from the blob. There is no flag day.

Re-encryption is not regeneration: the plaintext is unchanged, so ADR 0014's
rule that `postgres-app-password` is never regenerated is not engaged.

### 3.7 The region-change guard

Changing `REGION` migrates nothing. Terraform state is keyed by path, not
region: pointed at a new region it finds nothing, builds a second platform, and
leaves the first billing and invisible to state.

**The check cannot live in the offline gate of §3.2**, which is
credential-free by design; deciding this needs AWS access to look at buckets.
It goes in `scripts/state-up.sh`, the one place that creates the bucket:
refuse when `<project>-<other-region>-tf-state` exists and holds objects,
naming what to destroy first. It reuses the `count_resources` shape already in
`persistent-down.sh:53-81`.

Because §3.11 puts the region in the bucket name, the rest is **self-detecting**:
a different region means a different bucket, so terragrunt cannot silently
build a second platform against a backend that does not exist — it fails
closed. The guard only has to cover the one command that would create it.

This converts a silently doubled cloud bill into an actionable error, at the
cost of one `make full-down` before a region move.

### 3.8 Two defects fixed here

- `terraform/modules/lab-role/main.tf:180` grants
  `arn:aws:rolesanywhere:eu-west-1:${local.account}:*`. It is the only
  hardcoded region literal left in live Terraform, `bootstrap/rolesanywhere/`
  is project-scoped, and the result is a **silent IAM denial** for any project
  outside `eu-west-1`. Neither ADR 0024 nor AWS-031 mentions it. Change to `*`.
- **ACM's lifecycle class is recorded inconsistently.** The code says Bootstrap
  (`terraform/live/bootstrap/acm/`, `/bootstrap/acm/certificate_arn`);
  `docs/architecture.md:664`, `docs/adr/0002:35` and the comment at
  `gitops/values.yaml:113` say Persistent. **The code is correct** — the
  certificate is DNS-validated against the delegated zone, is useless without
  it, and the zone is Bootstrap. Correct the three documents.

ACM itself is **not** a region blocker, although AWS-031 lists it as one: the
certificate is created in the same provider region as the NLB by construction,
so constitution §14 is satisfied automatically when both move together.

### 3.9 Governance

ADR 0039 records the decision and supersedes ADR 0024 **for the project layer
only**. ADR 0024's reasoning stands for everything it actually covers.

Constitution §19 currently forbids this outright — the region "MUST NOT be
re-derived from an environment variable, a workflow input, a `get_env`
default, or ambient AWS CLI/SDK region resolution", and "deploying into any
other region is a deliberate source change, not a configuration step".
Constitution §13.4 requires that amendment to land **with the ADR, before
implementation**.

`AWS-031` is `Z`/DEFERRED and records exactly this work. It is superseded.
`HETZ-175 §4` already specs `server_type` as a Hetzner-only input via
`HCLOUD_SERVER_TYPE`; that half is absorbed here and HETZ-175 keeps its
right-sizing half. `CIVO-175` is not an equivalent — its §2 says changing the
pool SKU "is a separate one-line change once decided".

### 3.10 CI

`.github/workflows/lifecycle-provider.yml` gains the three inputs. Hetzner CI
runs `NODE_COUNT=2` — one control plane and one worker, 11.56 GiB allocatable
against the platform's 6.38 GiB measured working set — leaving 3 for the lab
against the 5-server account limit.

HETZ-170's autoscaler leaves M1 as a consequence: at 3 + 2 there is no room
under the cap for it.

### 3.11 Bucket names carry the region

An S3 bucket name is unique across **every AWS account and every region**, and
a bucket lives in exactly one region. So `<project>-tf-state` can exist in one
region at a time, and a region move would be a delete-then-recreate against a
name AWS does not guarantee is immediately reusable.

Both project buckets therefore take the region:

| Today | Becomes |
|---|---|
| `<project>-tf-state` | `<project>-<provider-region>-tf-state` |
| `<project>-postgres-backups` | `<project>-<provider-region>-postgres-backups` |

**The region in the name is the *provider's*, lowercased — not the AWS
region.** The bucket is an AWS resource and lives in the project's AWS
region, but its name records whose state it holds. Using the AWS region
would leave two Civo regions sharing one bucket and one set of state keys:
a run in `FRA1` after a run in `LON1` would read a network id that exists
only in `LON1`, fail to find it through a `FRA1`-scoped provider, and plan a
fresh create — **orphaning the `LON1` network while reporting success**. The
same applies to Hetzner between `nbg1` and `hel1`.

| Provider | `REGION` | Bucket |
|---|---|---|
| `aws` | `eu-west-1` | `vk-lab-platform-eu-west-1-tf-state` |
| `civo` | `LON1` | `vk-civo-lab-lon1-tf-state` |
| `civo` | `FRA1` | `vk-civo-lab-fra1-tf-state` |
| `hetzner` | `hel1` | `vk-hetzner-lab-hel1-tf-state` |

This also makes §3.7's guard live immediately rather than dormant: it loops
the *provider's* regions, so it protects Civo and Hetzner now instead of
waiting for the AWS catalogue to widen.

**The region goes before the suffix, not after, and that is load-bearing.**
`lab-role` grants `arn:aws:s3:::*-tf-state` and `arn:aws:s3:::*-postgres-backups`
(`lab-role/main.tf:36,40`). A name ending in the region would no longer match
either wildcard and would need an IAM change; a name ending in the existing
suffix matches unchanged. **No `lab-role` edit is required.**

Length stays inside S3's 63-character limit: `PROJECT_NAME` is capped at 23,
the longest AWS region name is 14, and `-postgres-backups` is 17, totalling 56.

The account layer's own bucket (`<owner>-account-state`, `root.hcl:20-21`) is
**unchanged** — that layer is pinned to `eu-west-1` permanently, so a region in
its name would assert a variability it does not have.

Roughly ten sites construct these names: `root.hcl:34`,
`postgres-backups/main.tf:2`, and `STATE_BUCKET`/`BUCKET` in `state-up.sh`,
`state-down.sh`, `bootstrap-down.sh`, `account-down.sh`, `persistent-down.sh`,
`require-persistent.sh`, `force-clean-ci.sh` and `verify-no-leaks.sh`.

**Migration, measured 2026-09-21:** only one project has buckets at all.
`vk-hetzner-lab-tf-state` holds 7 objects and `vk-hetzner-lab-postgres-backups`
is empty; `vk-lab-platform` and `vk-civo-lab` have none.

**Operator decision: destroy rather than copy.** No cluster is running on any
target, so there is no state worth preserving. `PROVIDER=hetzner make
bootstrap-down` removes that project's zone, its Roles Anywhere chain and its
bucket; the next `bootstrap-up` recreates everything under the new name. That
is simpler than an `aws s3 sync`, needs no verification that copied state
matches, and re-proves HETZ-025 and HETZ-080 end to end as a side effect.

The committed secrets are unaffected and MUST NOT be regenerated: the two
cloud tokens and `root-domain.enc` are real external values, and the Hetzner
CA private key has to keep matching its committed certificate. They are
re-encrypted by §3.6, never re-created.

This is done **now, deliberately, because it is the cheapest it will ever be**.
Once several projects hold live state, renaming a state bucket means migrating
state that resources depend on, and a mistake there orphans resources nobody
can destroy.

### 3.12 `lab.yml` workflow inputs

`.github/workflows/lab.yml` is the operator-facing entry point and MUST expose
the three values, or they can only be set locally.

They take the shape `project_name` and `subdomain` already use — `type: string`,
`default: ""`, blank meaning the provider's default — with a comment saying what
blank resolves to. A `type: choice` cannot express the constraint: GitHub has no
dependent dropdowns, so one flat list could not say that `cx43` is valid in
`nbg1` but not in `hel1`. The gate rejects a bad combination in the job's first
seconds, which is where that check belongs.

This is the input ADR 0024 deleted, and its reasoning was sound then — "a
one-option `type: choice` still presents region as an operator knob". It is no
longer one option. ADR 0039 MUST say so explicitly, rather than leave a reader
thinking the earlier argument was simply reversed.

**A pre-existing gap this exposes:** `lab.yml`'s `provider` choice offers only
`aws` and `civo`. `hetzner` has been supported since HETZ-010 and `local` since
ADR 0038, and neither can be selected from the Actions tab. Adding `hetzner` is
HETZ-140's work, and `local` owns no cloud resources so it may not belong in a
billable workflow at all — but the new inputs are unreachable on Hetzner until
`provider` can name it, so this spec records the dependency rather than shipping
inputs that cannot be used.

### 3.13 `README.md`

The README under-documents the command surface **before this change**: 35 make
targets exist and the `## Usage` block lists about 15, while `PROVIDER` — the
whole multi-provider surface — appears once, in passing, in a GitHub Actions
note. Adding three variables without fixing that makes it worse.

`## Usage` MUST gain a complete target table grouped by lifecycle class, each
row naming the target, what it does and which variables affect it; and a
variable table giving every operator input, its default per provider and its
valid values, with a worked example per provider including the Hetzner 3 + 2
split. The `PROJECT_NAME`/`SUBDOMAIN` rules already in
`### Running more than one lab` stay where they are and are cross-referenced,
not duplicated.

## 4. Testing / acceptance criteria

- **No-op defaults.** `make -n` for every provider across all lifecycle
  targets differs from `main` by **exactly one line per gated target** — the
  gate's own invocation. No other line changes. Byte-identity is impossible
  once the gate is a prerequisite, so this is the criterion that can actually
  be met and proved.
- **Cross-provider rejection.** `PROVIDER=aws REGION=nbg1` and
  `PROVIDER=hetzner NODE_TYPE=t4g.medium` both fail before any cloud call, with
  no credentials available.
- **Region × type rejection.** `PROVIDER=hetzner NODE_TYPE=cx43 REGION=hel1`
  is refused, citing the 2026-09-21 measurement. `REGION=fsn1` is refused
  outright.
- **`local` rejection.** `PROVIDER=local` with any of the three set fails,
  naming that the target owns no cloud resources.
- **Hetzner 3 + 2.** The lab at `NODE_COUNT=3` and a CI run at `NODE_COUNT=2`
  coexist; `hcloud server list` shows 5 at peak and the account limit is not
  hit.
- **AWS regression.** `lifecycle-aws` green with no variables set;
  `terragrunt run --all plan` in `terraform/live/persistent` shows no changes.
- **Civo regression.** `lifecycle-civo` green; `persistent-civo` plan shows no
  changes.
- **Account layer pinned.** Every `account*` unit renders `eu-west-1` whatever
  `REGION` is set to.
- **KMS migration.** All 12 `.enc` files round-trip against the new key before
  anything is removed; a full `up`/`test`/`down` passes on both AWS and Civo;
  only then is the old key scheduled for deletion.
- **Region move.** A full `bootstrap-up` → `persistent-up` → `up` in a second
  AWS region reaches Healthy, proving the KMS migration end to end, then is
  destroyed.
- **Guard.** Changing `REGION` with live state fails and names the destroy
  command to run first.
- **Two regions at once.** Two projects, one in `eu-west-1` and one elsewhere,
  both reach Healthy simultaneously; each project's `verify-no-leaks` passes
  against its own region.
- **README.** Every one of the 35 targets appears; every variable has a
  default and valid values; each provider has a worked example.
- **Bucket migration.** After `bootstrap-down` and a fresh `bootstrap-up`,
  the Hetzner project's state lives in `vk-hetzner-lab-eu-west-1-tf-state`,
  no bucket without a region in its name remains for any project, and
  `lab-role` is **not** edited because its two wildcards still match.
- **Workflow inputs.** A `lab.yml` run with the three inputs blank behaves
  exactly as before; a run with a bad combination fails in the gate, not in a
  cloud call.
- `make specs-check`, `make gitops-check` and `make secrets-check` green.

## 5. Risks and deferred work

### 5.1 `make clusters` is incomplete under multi-region — deferred

`scripts/clusters.sh` is the only genuinely account-scoped tool here. Its
header promises *"every platform EKS cluster live in this AWS account,
whatever its PROJECT_NAME"*, but `aws eks list-clusters --region "$LAB_REGION"`
and the node count at `:38` query one region. With projects in two regions it
under-reports while claiming completeness.

It cannot take a project region — `make clusters` accepts no `PROJECT_NAME` by
design — so the fix is to loop the catalogue's region list. **Deferred by
operator decision.** Until it lands, its output is complete only for the
default region.

Every other sweep is project-scoped and follows its own project's region:
`verify-no-leaks.sh`, `force-clean-ci.sh`, `status.sh`.

### 5.2 One project in two regions at once — deferred to its own spec

This spec lets a project **choose** its region. It does not let one project
**occupy two at once**, and the operator has asked for that as a follow-up
after the KMS migration.

Per-region SSM paths are necessary but **not sufficient**. Measured
2026-09-21: all 22 SSM parameters are `/<project>/…` with no region, and they
fall into three groups that need different treatment, so a blanket region
prefix would be wrong:

| Group | Examples | Treatment |
|---|---|---|
| Region-varying | `persistent-civo/network/id`, `cluster-civo/k8s/*`, `persistent-hetzner/*`, `cluster/eks/node_subnet_id`, `persistent/vpc/vpc_id`, `bootstrap/acm/certificate_arn` | MUST gain the region |
| Region-invariant | `persistent/postgres/app_password`, `persistent/grafana/admin_password`, `persistent/argocd/admin_password_bcrypt` | MUST NOT — one credential per project, whatever region it runs in |
| Needs a decision | `bootstrap/route53/*`, `bootstrap/rolesanywhere/*` | see below |

Three other collisions have to be solved in the same spec, and two are harder
than SSM:

- **The Route 53 zone.** One `<subdomain>.<root-domain>` per project. Two
  regions both create it. Either each region takes its own subdomain — which
  changes every URL — or one zone is shared and its records are region-scoped,
  which means deciding who owns the zone's lifecycle.
- **The Roles Anywhere trust anchor**, `<project>-<provider>-workload-ca`: one
  per project by HETZ-018's naming, so two regions collide on the name.
- **The backups bucket** is already region-namespaced by §3.11, so it is done.

Until that spec lands, two regions in parallel means **two projects** —
`PROJECT_NAME` and `SUBDOMAIN` already namespace everything, and that works
today with no new code. §3.7's guard refuses the same-project case, which is
the correct behaviour rather than a limitation to work around.

### 5.2 Other risks

- **Service quotas are per region.** A region never used before starts at AWS
  defaults for VPCs, EIPs, EKS clusters and Graviton vCPUs. Nothing here
  detects that; the first apply can fail on a quota rather than on the code.
- **Availability-zone names are per account.** `postgres_az` derives as
  `"${local.aws_region}a"` and follows the region for free, but AWS maps AZ
  names to physical zones differently per account, and an `a` zone is not
  guaranteed to offer the chosen instance type. This fails at node-group
  creation, not at plan.
- **S3 bucket names carry the region** (§3.11), so the global-uniqueness
  constraint that used to make a region move a delete-and-recreate race no
  longer applies. Migrating to the new names is a one-time step, costed in
  §3.11.
- **Karpenter's instance list** carries the same region-availability
  constraint as `NODE_TYPE` and is not governed by the catalogue.
- **The allowlist goes stale.** Clouds change catalogues: HETZ-020 found
  `cx22` gone entirely and `cpx11` deprecated in the EU within one spike. The
  dated comments required by §3.1 are what make a refresh auditable.

## 6. Evidence and status history

- 2026-09-21 — created as READY, from a design agreed with the operator in
  session. Measured on `main` at `e034a87`.

  Decisions taken: every cloud provider including the AWS region, with the
  account layer pinned to `eu-west-1` permanently; offline static allowlist
  rather than a live probe; `NODE_COUNT` counts every billed node in the fixed
  pool; per-provider cost ceilings with AWS widened to about 63 USD so that
  target has an upgrade path; Hetzner 3 for the lab and 2 for CI; the region
  guard in §3.7; a new multi-region KMS key with full re-encryption rather
  than an aliased provider; `make clusters` deferred.

  Prices in §3.1 were queried live on 2026-09-21 from the Hetzner API and the
  AWS Pricing API. Civo's are from `civo/research.md:29`, recorded 2026-09-07
  and not re-verified. The Hetzner region × type rows are HETZ-020's real
  creates, not Hetzner's published catalogue.

  Corrections this spec carries: the Hetzner limit is per account, not per
  project (`HETZ-140:57` is wrong); there are three `SecureString` parameters
  bound to `alias/lab-secrets`, not two; ACM is not a region blocker; ACM's
  lifecycle class is Bootstrap in code and Persistent in three documents; and
  `lab-role` hardcodes `eu-west-1` in one Resource element.
