---
id: "SHARED-047"
title: "MIN_WORKER_NODES and MAX_WORKER_NODES replace NODE_COUNT on every target"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "One operator concept has to land on three clouds whose elastic capacity is bounded three different ways, one of which counts no nodes at all"
effort_estimate: "One session (3-4 h), no live apply required"
estimate_confidence: "high"
depends_on: ["SHARED-044", "HETZ-178"]
blocked_by: []
supersedes: []
created: "2026-09-24"
updated: "2026-09-24"
completed: "2026-09-24"
---

# SHARED-047 — A worker range, on every cloud

## 1. Outcome and rationale

`NODE_COUNT` is removed. `MIN_WORKER_NODES` and `MAX_WORKER_NODES` replace it
on `aws`, `civo` and `hetzner`, and `NODE_TYPE` becomes `WORKER_NODE_TYPE`.
`local` continues to take none of them.

`NODE_COUNT` named the fixed pool and said nothing about the ceiling. Every
ceiling that existed therefore lived somewhere the operator input never
reached — Karpenter's `cpuLimit: 4`, Civo's `max: 4`, Hetzner's literal
`maxSize: 1`. Widening any of them meant editing a chart value or a template,
not changing an input.

Nothing about any cluster changes. The defaults reproduce every shipped value.

## 2. What the two inputs mean

> `MIN_WORKER_NODES` and `MAX_WORKER_NODES` count **worker nodes only**.
> A control plane is never one of them, whether the cloud owns it or this
> platform does.

This **supersedes SHARED-044 §3.3**, which counted Hetzner's control plane
*because it was schedulable*. HETZ-178 tainted it, so that reason is gone.

## 3. How each target expresses the range

| Target | MIN_WORKER_NODES | MAX_WORKER_NODES |
|---|---|---|
| `hetzner` | fixed `hcloud_server.worker` count | autoscaler `maxSize = MAX − MIN`, on a group **beside** the fixed pool, with `minSize` always 0 |
| `civo` | pool create count, and the autoscaler's `minSize` | autoscaler `maxSize`, absolute, on the **same** pool Terraform created |
| `aws` | EKS system node group, still pinned `min = max = desired` | each Karpenter NodePool's `limits.cpu = (MAX − MIN) × 2` |
| `local` | ignored | ignored |

**The civo/hetzner difference is real, not cosmetic.** Hetzner's autoscaler
owns a node group the fixed pool is not part of, so its ceiling is a delta.
Civo's owns the pool it was created with, so both bounds are absolute. The
operator-facing meaning is identical on both: total worker nodes stay between
MIN and MAX.

**On aws, one node is defined as 2 vCPU.** A fixed constant, not the vCPU count
of `WORKER_NODE_TYPE`, so the number does not move when the system node group's
type changes. Karpenter has no node-count setting at all; `limits.cpu` on each
NodePool is its only bound. Both NodePools get the **whole** budget rather than
a split, because when spot capacity runs out on-demand has to be able to absorb
all of it — so the worst case is double, which is already true today.

One inexactness survives, and it is not new: `gitops/bootstrap/values.yaml`
lists six instance types, of which `m6g.medium` and `m7g.medium` are 1 vCPU. A
4 vCPU budget can therefore realize as 2 large nodes or 4 medium ones. The
budget is exact; what it buys is not, and `nodepool.yaml:58-59` already said so.
Narrowing those lists would close the gap and was rejected: it would change aws
behaviour, which this work must not do.

## 4. Defaults, and why they are these

| Target | MIN | MAX | Reason |
|---|---|---|---|
| `aws` | 1 | 3 | `(3 − 1) × 2 = 4`, Karpenter's shipped `cpuLimit` |
| `civo` | 3 | 4 | CIVO-170's bounds, unchanged |
| `hetzner` | 1 | 2 | 1 control plane + 1 fixed + 1 elastic = 3 of the account's 5, leaving 2 for CI |

## 5. Validation

The offline gate gains three rules. Both values must be positive integers, and
both are checked for that **before** either is compared, so a non-numeric value
never reaches an arithmetic test that would abort the shell. `MAX` must be at
least `MIN`. On `hetzner` alone, `MAX` may not exceed 3, because Hetzner sells
five servers per account and shares them with CI; a run that takes four leaves
CI unable to start. The message names that limit rather than stating a bare
number.

## 6. What this also fixed

HETZ-178 shipped a defect. The Makefile pinned hetzner's `NODE_TYPE` to `cx43`
unconditionally, which overrode the region-keyed catalogue default that same
change had just introduced, so `REGION=hel1 make up` was refused on a type the
operator never chose. Reproduced against `main` before the fix:

```
Refusing: invalid node configuration for PROVIDER=hetzner
  - NODE_TYPE 'cx43' is not allowed in 'hel1'; there: cx23 cx33 cpx32 cpx42
```

The literal is gone. `provider.sh` resolves the worker type after the region is
canonicalised, which is what keying the catalogue by (provider, region) was for.

## 7. CI

The Hetzner leg drops to `min_worker_nodes: "1"` and `max_worker_nodes: "1"` —
one fixed worker and no elastic capacity, two servers in total, leaving the lab
its three. CI drives no load, so a ceiling above the floor would buy nothing and
risk a server slot.

## 8. Acceptance criteria

| Criterion | Status |
|---|---|
| Every target's rendered bounds are unchanged from before the rename | pass — aws `cpuLimit: 4`, civo `3:4`, hetzner `0:1:CX43:FSN1` |
| `MAX < MIN` is refused; a non-integer is refused; `MAX = 4` on hetzner is refused | pass, `tests/scripts/node-config-test.sh`, 18 cases |
| `wait_for_nodes_ready` expects `MIN_WORKER_NODES + 1` on hetzner and `MIN_WORKER_NODES` elsewhere | pass, `tests/scripts/node-ready-test.sh`, 9 cases |
| Every hetzner region resolves to a worker type it sells, through `make` | pass — `hel1` gives `cx33`, `fsn1` and `nbg1` give `cx43` |
| `make scripts-check`, `make gitops-check`, `make node-config-check`, `terraform fmt`, `terraform validate` on all three cluster modules | pass |
| The aws golden render is unchanged | pass — the root Application's parameters did not change |
| A lifecycle run on hetzner and on civo | outstanding — those are the two targets whose bring-up path changes shape |
