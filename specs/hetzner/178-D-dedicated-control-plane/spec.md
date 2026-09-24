---
id: "HETZ-178"
title: "A dedicated, tainted control plane on its own small server type"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "strongest"
model_rationale: "Reverses a recorded decision and changes what the node-count input counts; the reasoning matters more than the diff, which is small"
effort_estimate: "One session (2-3 h) plus one live cycle"
estimate_confidence: "high"
depends_on: ["HETZ-030", "HETZ-170"]
blocked_by: []
supersedes: []
created: "2026-09-24"
updated: "2026-09-24"
completed: "2026-09-24"
---

# HETZ-178 — A dedicated, tainted control plane

## 1. Outcome and rationale

The Hetzner control plane stops carrying workloads. It is created on `cx23`
rather than the worker type, and k3s taints it
`node-role.kubernetes.io/control-plane=true:NoSchedule` at first boot. The
worker default rises to `cx43`, so the fixed pool becomes one small control
plane and one large worker.

This reverses `decisions.md`'s "Schedulable control plane" row, which chose the
shared node. That row rejected a dedicated control plane because "(a) doubles
the fixed pool for no gain on a single-tenant lab". **The premise was wrong.**
The control plane is already its own `hcloud_server` (`hcloud-nodes/main.tf:42`)
and always has been, so dedicating it adds no server — it shrinks the one that
exists. Hetzner's limit is server count per account, not spend, which makes that
distinction the whole argument.

## 2. Why a taint, and not the mitigations the old row named

Three facts about k3s, verified rather than assumed.

**The control plane is not pods.** `k3s server` runs the API server, the
controller manager, the scheduler and embedded etcd as goroutines in one process
under `k3s.service`. PriorityClass, preemption, kubelet eviction ranking and
PodDisruptionBudgets all act on pods. None of them can reach it. The mitigations
the old row relied on — a `platform-critical` PriorityClass and soft affinity
away from the control plane — protect other pods from each other. They never
protected the control plane, and neither of them was ever built.

**Memory is protected; CPU and disk are not.** The kubelet's
`enforceNodeAllocatable` defaults to `["pods"]`, which caps the `kubepods` cgroup
at Allocatable, so pod memory cannot reach the 1.5 GiB the install line reserves.
CPU is divided by cgroup weight rather than reserved, and nothing sets an I/O
limit. etcd commits every write with an fsync, so disk contention degrades it
directly.

**Supervision is systemd and nothing else.** The k3s installer writes
`Restart=always` and `RestartSec=5s`, with no `MemoryMax`, no `CPUWeight` and no
`OOMScoreAdjust`. A crash is loud and self-healing. Degradation under contention
is silent, never restarts, and disables the scheduler and the autoscaler that
would otherwise recover the cluster.

Node isolation is therefore the only mechanism this target offers, and a taint
is how it is spelled.

## 3. The taint does not break bring-up

Two gates stand between a tainted control plane and a working cluster, and both
were checked against the real charts before the change was written.

| Component | Tolerates the control-plane taint | Source |
|---|---|---|
| hcloud cloud controller manager | yes | chart 1.37.0 rendered, `tolerations` lines 128-134 |
| k3s bundled CoreDNS | yes | `manifests/coredns.yaml:108-110`, v1.36.4+k3s1 |

So the CCM still schedules, still clears
`node.cloudprovider.kubernetes.io/uninitialized`, and CoreDNS still becomes
Available. `wait_for_nodes_initialized` is unchanged and still passes.
`wait_for_nodes_ready` counts nodes that are Ready, not schedulable, so a
tainted control plane satisfies it as before.

## 4. The operator surface

`CONTROL_PLANE_NODE_TYPE` joins `REGION`, `NODE_TYPE` and `NODE_COUNT` as a
validated operator input. Hetzner only: on any other provider a non-blank value
is refused rather than ignored, because nothing there would read it. `local`
continues to ignore every node input, as it already did.

It is validated against the same per-region list in `scripts/lib/catalog.sh` that
`NODE_TYPE` uses, which also makes it the escape hatch when a server type is out
of stock — a failure this target has hit before (`lifecycle-test.yml:552-555`).

`catalog_default_node_type` is now keyed by (provider, region), like
`catalog_node_types` beside it. Without that the new `cx43` default would name a
type `hel1` does not sell, which is the exact failure the file's own header
warns against: "flat lists would accept combinations that cannot be created."
`hel1` resolves to `cx33`; `fsn1` and `nbg1` resolve to `cx43`.

## 5. The node plan, and what it costs

Prices are `catalog.sh`'s gross figures, one basis throughout.

| | Fixed servers | Schedulable memory | Gross/month |
|---|---|---|---|
| Before: `cx33` control plane + `cx33` worker | 2 | 11.56 GiB, split | 24.18 |
| After: `cx23` control plane + `cx43` worker | 2 | ~14.2 GiB, on one node | 30.22 |

Same two servers, so the same three slots stay free under the account's limit of
five. The autoscaler still adds at most one worker, leaving two slots for CI.

The workload was measured rather than estimated, by rendering the target and
reading the three charts installed outside Argo:

| | CPU | Memory |
|---|---|---|
| Singletons | 1010m | 3166 MiB |
| Per node (alloy, hcloud-csi node, node-exporter) | 45m | 200 MiB |

Two figures qualify that total. kube-prometheus-stack alone is 1600 MiB of it,
which HETZ-175 right-sizes on measured data. And Argo CD's seven workloads
declare no requests at all, so roughly 500-800 MiB of real use is invisible to
the scheduler. Budget about 5 GiB of real memory. One `cx33` worker was
therefore rejected: it would leave under a gigabyte.

## 6. Accepted risks

**One fixed worker is a single point of failure.** Every stateful workload
already runs at one replica with `enablePDB: false`, so this changes the
exposure, not the design. A cluster that loses its worker is rebuilt with
`make up`, which is what disposable means here.

**`cx23` stock.** The whole `cx` line read unavailable in every location on
2026-09-23. `CONTROL_PLANE_NODE_TYPE` exists partly for that; HETZ-175 owns the
real fallback.

## 7. Acceptance criteria

| Criterion | Status |
|---|---|
| `CONTROL_PLANE_NODE_TYPE` is refused on aws, civo and local, and refused for a type the chosen region does not sell | pass, `tests/scripts/node-config-test.sh` |
| Every Hetzner region resolves to a worker type it actually sells | pass, `hel1` gives `cx33`, `fsn1` and `nbg1` give `cx43` |
| `make scripts-check`, `make gitops-check`, `make node-config-check`, `terraform fmt`, `terraform validate` | pass |
| The control plane carries the taint after `make up` | outstanding, needs a live cycle |
| CoreDNS and the CCM run on the control plane; every other singleton runs on the worker | outstanding |
| The HETZ-170 burst test still scales the group 0→1→0 | outstanding |
| `terragrunt plan` on `cluster-hetzner` is clean while state is populated | outstanding — this also closes HETZ-170's last open criterion |

### What a live run must also record

`kubectl get --raw /api/v1/nodes/<cp>/proxy/configz | jq
.kubeletconfig.enforceNodeAllocatable`. §2 claims the kubelet default of
`["pods"]`, which was read from upstream rather than from this cluster. If k3s
sets something else, §2's second paragraph needs correcting — not the decision,
which rests on the first and third.
