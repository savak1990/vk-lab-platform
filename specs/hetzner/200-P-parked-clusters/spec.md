---
id: "HETZ-200"
title: "make park and make unpark: a cluster that keeps its control plane and loses its workers"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Adds the first new lifecycle command since the constitution forbade one, so the governance reasoning carries more risk than the diff; and the failure mode of getting it wrong is a teardown that deletes a live cluster"
effort_estimate: "One session (3 h) plus one live park/unpark cycle"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-170", "HETZ-178", "SHARED-047"]
blocked_by: []
supersedes: []
created: "2026-09-25"
updated: "2026-09-25"
---

# HETZ-200 — parked clusters

## 1. Outcome and rationale

`make park` takes the worker nodes to zero and leaves everything else: the
control plane, etcd, every Argo CD object, the volumes, the load balancer and
its DNS records. `make unpark` brings the workers back. The cluster answers
`kubectl` throughout and schedules nothing while parked.

The disposable lifecycle has had two states — a cluster exists or it does not.
This adds a third, for the case an operator actually has: finished for the day,
wanting the cluster tomorrow.

**The saving is not the argument.** A torn-down project is cheaper than a parked
one, because `cluster-down.sh` sweeps volumes as well as servers:

| | EUR/month |
|---|---|
| Running: cx23 control plane + cx43 worker + lb11 + 2 primary IPv4 + 20Gi volume | 35.61 |
| Parked | 16.62 |
| Torn down | ~0 |

What park buys is **time and in-cluster state**. A bring-up allows
`ARGO_UP_WATCH_SECONDS` of 2700 for the platform to reach Healthy, on top of a
600s node gate, a 180s cloud-controller gate and a 300s DNS gate; an unpark boots
one server and lets the scheduler place pods. The ACME issuers never re-issue, so
a habit of rebuilding cannot walk into Let's Encrypt's five-duplicates-per-week
limit. Postgres needs no dump and no restore, because the volume stays bound.

So the rule this spec ships with is: **park for hours, tear down for weeks.**

## 2. Why this is a new command, and why the constitution allows it

§20's §17 rows said Hetzner adds "no new lifecycle command". §17's only
exemption is `make clusters`, and it is justified by "It creates and destroys
nothing" — which park cannot claim.

§13 makes the amendment a precondition rather than a follow-up, so this spec
carries it. The reasoning that makes it a small amendment rather than a large
one: **park is a guarded modifier on the Disposable pair, not a fifth lifecycle
class.** It creates and destroys nothing outside the class `make up` and
`make down` already own, and it changes no other command's contract or guards.
That is the same ground `make full-up`/`full-down` stand on in §17, and the same
sentence applies to both — they are not a new lifecycle class.

A parked cluster is still Disposable. Nothing about the Persistent or Bootstrap
layers is reachable from either command.

## 3. What a parked cluster is

A **live, empty cluster**. The control plane is not pods: `k3s server` runs the
API server, the controller manager, the scheduler and embedded etcd as
goroutines in one systemd unit with `Restart=always`, so it keeps answering with
no worker present.

HETZ-178 is what makes this pleasant rather than awful. Before the control plane
was tainted, a zero-worker cluster would have tried to reschedule the whole
platform onto 2 vCPU. Now nothing lands there but what tolerates the taint:

| Component | Runs while parked | Source of the toleration |
|---|---|---|
| hcloud cloud controller manager | yes | chart default |
| k3s CoreDNS | yes | k3s bundled manifest |
| Alloy | yes | `alloy.yaml`, `operator: Exists` |
| node-exporter, hcloud-csi node plugin | yes | chart defaults |
| Argo CD, CNPG, Envoy, observability, the autoscaler | **no — Pending** | no toleration |

**Postgres is stopped, not running.** That is the contract, and it is why unpark
is a scheduling event rather than a restore.

A Pending Argo CD cannot self-heal, which is what makes the parked state stable
instead of fighting itself.

## 4. The operator surface

```
PROVIDER=hetzner make park
PROVIDER=hetzner make unpark
```

Both delegate to `scripts/park.sh <direction>`. Guards, in order:

1. Refuses on `aws`, `civo` and `local`, each with the reason. The aws message
   names AWS-034, which costed that decline.
2. Requires the cluster to exist and the API to be reachable. A park that cannot
   drain must not destroy a worker; an unpark has nothing to rejoin.
3. Requires Argo CD's root Application to exist, and **never deletes it.**
4. `park` on an already-parked cluster is a no-op that says so. `unpark` on a
   running one refuses.

Requirement 3 is the one that protects money rather than tidiness.
`cluster-down.sh` refuses to run while root exists, and a parked cluster's
surviving servers and volumes still carry the labels a teardown sweep matches
on. A park that removed root would quietly arm the next `make down` to delete a
live cluster.

No new operator input. **The offline `MIN_WORKER_NODES` gate stays strict**:
`require-valid-node-config` is a Make prerequisite rather than something the
script calls, so `park.sh` sets zero for itself and a mistyped
`MIN_WORKER_NODES=0 make up` is still refused. Only the Terraform validation
relaxes, from `> 0` to `>= 0`.

The parked state is **inferred from the absence of worker servers**, not stored.
No SSM parameter and no marker file: zero workers is the state, and it is
readable from the API park already talks to. `make clusters` shows a parked
project as one node.

## 5. What park does, in order

1. Drain every node that is not the control plane, so CNPG stops cleanly and the
   CSI driver detaches the volume instead of leaving it attached to a server
   about to vanish.
2. `terragrunt apply` with `MIN_WORKER_NODES=0`, which destroys the fixed
   workers and touches neither the control plane nor the firewall.
3. Delete any `managed_by=autoscaler` server. Those are not in Terraform's
   state, so step 2 does not touch them, and left alone they would keep billing
   beside a parked cluster.
4. Delete the stale `Node` objects.

Step 4 exists because nothing else in the repository reaps a `Node`, and
`wait_for_nodes_ready` requires every node present to be Ready. A leftover
`NotReady` object therefore wedges **the unpark**, not the park — the failure
appears one command later than the cause.

Unpark is step 2 in reverse at the real floor, then `wait_for_nodes_ready`. No
step 3 or 4, and no script re-run: the join token is a `random_password` held in
state, the join address is `cidrhost(subnet, 10)` from the persistent subnet, the
agent retries until the API answers, and the firewall attaches by label
selector. A worker recreated weeks later rejoins with no coordination and no SSH.

## 6. Why the load balancer stays up

It is the largest parked line item at 8.49 EUR/month, and while parked it routes
to a Pending pod. That is deliberate waste.

The hcloud load balancer carries no static-address annotation and its location is
immutable, so a recreated one takes a new address. Dropping it would mean
re-publishing DNS, waiting for propagation and re-entering the certificate path
on every unpark — which spends most of what park was bought for.

**Deferred, not rejected:** a pre-created Primary IP at 0.50 EUR/month would turn
8.49 of waste into 0.50, if the cloud controller manager can pin a load balancer
to one. That is unverified and is the first thing to test if the parked cost ever
matters more than it does now.

## 7. Accepted risks

- **Park destroys the only fixed worker**, so CNPG stops. The drain in §5 step 1
  is what makes that graceful. HETZ-120 already proves rows survive a full
  down/up cycle, which is rougher treatment than this.
- **Relaxing the Terraform floor** lets a zero-worker cluster be created by
  someone who bypasses the offline gate. Accepted: the gate is unchanged and
  `park.sh` is its only caller.
- **A parked cluster is not free.** Parking for weeks is the wrong choice; §1
  carries the rule and §8 measures the number it rests on.
- **The drain is best-effort.** A drain that does not finish inside
  `PARK_DRAIN_SECONDS` logs and continues, because a park that refuses to
  complete leaves a cluster in neither state. The volume is the thing at risk,
  and §8's live criterion is what checks it.

## 8. Acceptance criteria

| Criterion | Status |
|---|---|
| `park` refuses on aws, civo and local, each naming a reason rather than only refusing | pass, `tests/scripts/park-test.sh` |
| An unreachable API and a missing root Application both refuse **before** any `terragrunt` call | pass, `tests/scripts/park-test.sh` |
| A park drains, applies at `MIN_WORKER_NODES=0`, then deletes the stale `Node` — and never issues a delete against the root Application | pass, `tests/scripts/park-test.sh` |
| The drain happens before the apply that destroys the server | pass, `tests/scripts/park-test.sh` |
| A second `park` is a no-op: no drain, no apply | pass, `tests/scripts/park-test.sh` |
| `unpark` refuses while workers exist, and otherwise applies at the real floor | pass, `tests/scripts/park-test.sh` |
| `make scripts-check`, `terraform fmt`, `terraform validate` | pass |
| `make -n` for the existing lifecycle targets is unchanged | pass, additive targets only |
| A live cycle: `make full-up`, write a Postgres row, `make park`, `make unpark`, read the row back | outstanding |
| While parked: one server, the volume still present, `kubectl` answering, and `make clusters` showing the project | outstanding |
| The measured unpark time against the measured bring-up time, which is the number §1's park-for-hours rule rests on | outstanding |
| Two park/unpark cycles in succession, to catch state that only breaks the second time | outstanding |

Criteria 1-8 need no cloud. The last four need one live cycle.

## 9. Evidence

**Offline, 2026-09-25.** `make scripts-check` passes, including the new
`tests/scripts/park-test.sh`, picked up by the existing `tests/scripts/*-test.sh`
glob with no registration. `shellcheck -x -S warning` clean. `terraform fmt`
clean.

Both mechanical criteria were **verified by reversal** rather than by passing:
removing the `kubectl delete node` step makes the test report the stale-Node
failure, and changing the applied count from 0 to 1 makes it report the wrong
count. Restored, both pass.

Two defects the tests found before any cloud was involved:

- **A 600s hang.** The fake `kubectl` did not model the worker returning after an
  unpark, so `wait_for_nodes_ready` sat through its whole budget. The fixture now
  models the node appearing after the apply, and every wait is capped to seconds
  inside the test, so a regression fails in about ten seconds rather than looking
  like a hang.
- **The inherited-export freeze, again.** `make` exports `CLUSTER_DIR` into every
  recipe, and `provider.sh` derives it with `${X:-default}`, which cannot change
  an already-exported value. The test set `PROVIDER=hetzner` while inheriting the
  aws `CLUSTER_DIR`, so `park.sh` walked into the **EKS** stack directory
  believing it was on Hetzner. It passed standalone and failed under `make`. The
  test now clears the inherited exports instead of overriding them, which is the
  same remedy SHARED-046 reached for the same cause. Worth recording plainly:
  the uncaught version of this applies a zero-worker plan to the AWS stack.

**Outstanding: the live cycle.** No cluster existed on any provider when this
shipped, and the persistent Hetzner layer had been torn down too, so the run
needs `make full-up` rather than `make up`.

## 10. Constitution amendments

§17 gains a bullet for the pair, with its guards, placed after the
`full-up`/`full-down` bullet whose reasoning it shares.

§20's two §17 rows are amended to permit this one pair, and record that only the
Hetzner arm is implemented. The Civo row keeps its force for every other
command.

ADR 0041 records the decision, the alternatives — powering servers off, a worker
snapshot, park on AWS, park on Civo, scaling workloads instead of nodes, and
storing the parked state — and why each was rejected.

## 11. Not in this spec

- **Park on Civo.** The best target on paper, since its control plane is free, so
  a parked Civo cluster costs no more than a deleted one, and Terraform already
  concedes the pool count. But the in-cluster autoscaler owns that count with an
  absolute `minSize` under `selfHeal: true`, so park would have to disarm and
  re-arm it, and whether the Civo API accepts a pool count of zero is
  undocumented and untested. More code and an unproven dependency, for a target
  the operator does not park.
- **Park on AWS.** Declined and costed in AWS-034.
- **The `local` target**, which owns no cloud resources.
- **Dropping the load balancer while parked** (§6).
- **An Argo CD sync suspension.** Not needed: a Pending Argo CD cannot sync.
