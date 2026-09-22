---
id: "SHARED-045"
title: "One project occupies two Civo regions or two Hetzner locations at once"
status: "DRAFT"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "A naming change across 22 SSM parameters, a Route 53 zone whose lifecycle owner is undecided, and a regional identity chain; the failure mode is one region silently reading another's state"
effort_estimate: "Two sessions, plus one live two-region bring-up to prove it"
estimate_confidence: "low"
depends_on: ["SHARED-044"]
blocked_by: []
supersedes: []
created: "2026-09-22"
updated: "2026-09-22"
completed: ""
---

# SHARED-045 — one project in two regions at once

## 1. Outcome and rationale

One project name runs a cluster in two Civo regions, or two Hetzner locations,
at the same time. Today it cannot: every AWS-side name a project owns is
`/<project>/…` with no region in it, so the second region overwrites the
first's configuration.

The operator's words, 2026-09-21: *"civo and hetzner must support simultaneous
runs … today we have to always shutdown cluster in one region in order to
start in another region."*

**This is a naming problem, not a region problem.** [SHARED-044](../044-A-node-and-region-inputs/spec.md)
already made `REGION` a validated input and put the provider's region into
both S3 bucket names. What remains is everything else a project names once.

AWS is out of scope by construction: [ADR 0040](../../../docs/adr/0040-the-aws-region-stays-fixed.md)
fixes the AWS region at `eu-west-1` permanently, so an AWS project cannot span
two regions and this spec never asks it to. The AWS-side resources of a Civo or
Hetzner project still all live in `eu-west-1`; it is their **names** that must
carry the provider's region.

### What works today, and why this is P2

Two regions in parallel already works as **two projects**:

```
PROJECT_NAME=vk-civo-lab-fra SUBDOMAIN=civo-fra REGION=FRA1 make full-up
```

`PROJECT_NAME` and `SUBDOMAIN` namespace state, SSM, the Route 53 zone and the
Roles Anywhere chain, with no new code. SHARED-044 §3.7's guard refuses the
same-project case deliberately — it converts a silently doubled cloud bill into
an actionable error.

So this spec buys convenience, not capability. That is why it is P2.

## 2. Scope and non-goals

In scope:

- The 22 SSM parameters under `/<project>/…`, split three ways (§3.1).
- The Route 53 zone one project owns (§3.2).
- The Roles Anywhere trust anchor and profile, which are regional (§3.3).
- `make clusters`, which sweeps one region only (§3.4).
- Whatever `scripts/lib/region.sh` and `terraform/live/root.hcl` must expose so
  a Terragrunt unit can build a region-scoped SSM path.

Not in scope:

- **AWS.** Fixed at `eu-west-1` by ADR 0040.
- **The two S3 buckets.** SHARED-044 §3.11 already region-namespaced both.
- **Relaxing the §3.7 region-change guard.** It must keep refusing a project
  that moves its single region, and must learn to allow a project that adds
  one. Those are different cases and the guard must tell them apart.
- **A third region.** The design must not forbid it, but nothing is proved
  beyond two.

## 3. Requirements

### 3.1 SSM parameters split three ways

Measured 2026-09-21: all 22 parameters are `/<project>/…` with no region. A
blanket region prefix would be wrong — a credential must not fork per region.

| Group | Examples | Treatment |
|---|---|---|
| Region-varying | `persistent-civo/network/id`, `cluster-civo/k8s/*`, `persistent-hetzner/*`, `cluster/eks/node_subnet_id`, `persistent/vpc/vpc_id`, `bootstrap/acm/certificate_arn` | MUST gain the provider's region |
| Region-invariant | `persistent/postgres/app_password`, `persistent/grafana/admin_password`, `persistent/argocd/admin_password_bcrypt` | MUST NOT — one credential per project, whatever region it runs in |
| Needs a decision | `bootstrap/route53/*`, `bootstrap/rolesanywhere/*` | §3.2 and §3.3 |

The region goes in the path, not the parameter name, so an
`Option=BeginsWith` sweep of one region stays possible — the teardown scripts
and `lab.yml`'s stale-parameter cleanup both rely on that shape.

### 3.2 The Route 53 zone — distinct SUBDOMAIN per region

One project owns one `<subdomain>.<root-domain>` zone. Two regions both try to
create it.

**Decision (operator, 2026-09-21): each region takes its own `SUBDOMAIN`.**
`REGION=FRA1` gets `civo-fra.<root-domain>`, `REGION=LON1` gets
`civo-lon.<root-domain>`. The zone, its delegation record and its ACM
certificate stay exactly as they are — one owner, one lifecycle, no shared
mutable resource and no new ownership question.

The cost is that every URL changes with the region, so a bookmark or a client
config is region-specific.

> **Open question, recorded verbatim from the operator:** *"maybe we will need
> to think about better mapping here."* The alternative is one shared zone with
> region-scoped records, which keeps URLs stable but requires deciding who owns
> the zone's lifecycle when either region can be torn down independently. This
> must be settled before implementation starts; it is the main reason the spec
> is `DRAFT` rather than `READY`.

The rejected shape is worth recording: `require-unique-subdomain.sh` refuses a
zone another project already owns. Under a shared zone it would have to learn
the difference between "another project" and "the same project, other region",
which is state it does not have.

### 3.3 Roles Anywhere becomes per project per region

Roles Anywhere is a **regional** service — `arn:aws:rolesanywhere:<region>:…`.
This is not only a naming collision: a project spanning two regions needs a
trust anchor and a profile in each one, whatever they are called.

Today HETZ-018 names them `<project>-<provider>-workload-ca` and
`<project>-<provider>`. Both MUST gain the provider's region.

Two things deliberately do not multiply:

- **The IAM roles stay global and stay one set.** `<project>-ra-<consumer>` is
  an IAM resource and IAM is not regional. Minting four more per region would
  be duplication with no isolation gained. What changes is their trust
  policies: they condition on `aws:SourceArn` and MUST accept **every**
  region's anchor, not one.
- **The CA stays one per project.** The committed certificate is material, not
  an AWS resource, and the same certificate registers as an anchor in each
  region. A second CA means a second ceremony and a second private key to hold,
  for no security gain.

### 3.4 `make clusters` sweeps every region

`make clusters` lists one region. Under two regions it reports half the truth,
which is worse than reporting none — an operator reads "no clusters" and walks
away from a running bill.

It MUST iterate the catalogue's regions for the provider, or state plainly
which region it looked at. Carried forward from SHARED-044 §5.1.

### 3.5 The region-change guard learns two cases

SHARED-044 §3.7's guard in `scripts/state-up.sh` refuses to create
`<project>-<region>-tf-state` when `<project>-<other-region>-tf-state` exists
and holds objects.

That is correct for a **move** and wrong for an **add**. The guard MUST
distinguish them by an explicit operator input rather than by inference — a
second region is always deliberate, and inferring it from bucket contents
would silently re-enable the doubled bill the guard exists to prevent.

## 4. Testing / acceptance criteria

1. `make full-up` in `LON1`, then `make full-up` in `FRA1` for the **same**
   `PROJECT_NAME`, both succeed and both clusters serve traffic.
2. Each region's Postgres recovers its own data across `make down` / `make up`,
   and neither reads the other's backup generation.
3. The three region-invariant credentials are read identically by both
   regions — one Grafana password, not two.
4. `make clusters` lists both.
5. `make full-down` in `FRA1` leaves `LON1` fully serving: no shared resource
   is destroyed, and the region-invariant parameters survive.
6. `make full-down` in `LON1` afterwards leaves no leak in either region.
7. The region-change guard still refuses an undeclared region move.

Steps 1, 5 and 6 need a live two-region bring-up. There is no offline
substitute: the failure this spec fixes is one region reading another's SSM
value, which only a real apply exercises.

## 5. Risks and open questions

1. **The Route 53 decision is not final** (§3.2). Implementation must not start
   before it is.
2. **A partial rename is worse than none.** A parameter that gains the region
   in the writer but not the reader fails at apply time in the second region
   only, which is the hardest place to see it. The rename lands as one change
   across writer and reader, with `gitops-render-check` and the golden files
   proving no path drifted.
3. **Roles Anywhere trust policies are edited, not replaced.** A policy that
   accepts only the new region's anchor locks the first region's workloads out
   of AWS while they are running.
4. **Cost doubles by design.** Two regions means two clusters, two load
   balancers and two sets of nodes. The guard of §3.5 is what keeps that
   deliberate.

## 6. Evidence and status history

- 2026-09-21 — analysis performed as SHARED-044 §5.2: the 22 SSM parameters
  measured and grouped, Route 53 and Roles Anywhere collisions identified, the
  IAM-roles-stay-global and one-CA-per-project decisions taken by the operator.
- 2026-09-21 — operator chose a distinct `SUBDOMAIN` per region, with the
  caveat recorded in §3.2.
- 2026-09-22 — extracted into this spec at the operator's request, priority P2.
  SHARED-044 §5.2 now points here.
