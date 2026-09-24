---
id: "SHARED-048"
title: "Right-size workload requests and limits on measured data, once, for every target"
status: "DONE"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "The judgement is in reading two conflicting measurements, not in the edit"
effort_estimate: "One session"
estimate_confidence: "high"
depends_on: ["CIVO-160"]
blocked_by: []
supersedes: ["CIVO-175"]
created: "2026-09-24"
updated: "2026-09-24"
completed: "2026-09-24"
---

# SHARED-048 — Right-sizing, once, for every target

## 1. Outcome and rationale

Every long-lived workload the platform installs declares a CPU request, a
memory request and a memory ceiling. Each number is either a measurement plus
headroom, or an upstream default this spec states a reason to keep.

Right-sizing was three specs: CIVO-175, the right-sizing half of HETZ-175, and
nothing at all on aws. The requests are shared values rendered for all four
targets, so one spec changes all of them and three specs would have changed the
same lines three times. This spec replaces CIVO-175 and takes the right-sizing
half of HETZ-175. HETZ-175 keeps its number and its other half, the stock-aware
SKU fallback, which is a Hetzner Terraform change and unrelated to requests.

The platform is an educational lab. It carries no production traffic, so the
target is the smallest declaration that does not cause an eviction, plus a
stated buffer — not a number sized for a load that never arrives.

## 2. Scope and non-goals

In scope: `resources` on every workload in `gitops/`, the Argo CD and hcloud
CCM releases `scripts/argo-up.sh` installs, and the Roles Anywhere sidecar.

Not in scope, each for a reason stated in §5: Prometheus and Grafana memory,
the observability retention and volume sizes, the Postgres volume, and
per-target overrides. Also out of scope: CPU ceilings, which the platform sets
nowhere by an existing decision.

## 3. The measurements this rests on

Two live readings exist. They disagree, and the disagreement is the reason
Prometheus is left alone.

**Civo, 2026-09-17, 3 × Medium, after a full Argo sync** (CIVO-160 §14). Top
pods by working set: grafana 589Mi, prometheus 307Mi, loki 161Mi, alloy 57–75Mi
per node. Two of three nodes ran over their own 2308 MiB allocatable.

**aws, before 2026-09-16.** The comment at
`gitops/templates/platform/shared/observability/kube-prometheus-stack.yaml`
records "~665Mi over 45m" for Prometheus, measured before the stack was hoisted
to the shared tree.

The two are not in conflict once read properly. Civo scrapes no control-plane
component; hetzner turns kube-controller-manager, kube-scheduler and etcd
scrapes on. 307Mi is the floor of the three targets, not the representative
figure, and the shared value has to hold the ceiling.

**Failures recorded in the same run**, and never acted on until now: the
cert-manager controller restarted 5+2 times with `Error`, and
`cert-manager-cainjector` was `OOMKilled` once at a 64Mi ceiling.
`argocd-application-controller-0` was `OOMKilled` twice at a 768Mi ceiling and
was raised to 1152Mi at the time.

## 4. What changed

| Workload | Was | Now | Why |
|---|---|---|---|
| cert-manager controller | 10m / 32Mi, limit 64Mi | 10m / 48Mi, limit 128Mi | restarted seven times with `Error` on 2026-09-17 |
| cert-manager cainjector | 10m / 32Mi, limit 64Mi | 10m / 64Mi, limit 128Mi | `OOMKilled` at that ceiling on 2026-09-17 |
| CNPG `lab-postgres` | 250m / 256Mi, no ceiling | 100m / 256Mi, limit 512Mi | the largest CPU request in the platform, for a one-instance lab database, and the only long-lived workload with no memory ceiling |
| Roles Anywhere sidecar | 10m / 16Mi, no ceiling | 10m / 16Mi, limit 32Mi | injected into three pods on civo and hetzner, none of them capped |
| hcloud CCM | chart default 100m / 50Mi, no ceiling | 10m / 32Mi, limit 64Mi | it reconciles node objects and routes on a two-node cluster |
| envoy-gateway webhook probe Job | nothing at all | 10m / 32Mi, limit 64Mi | the one workload that declared no `resources` block; BestEffort, and it runs on every sync |

Both cert-manager templates change, the shared one and the aws one.

The CNPG ceiling does not resize the cache: `shared_buffers` is deliberately
unset (`cluster.yaml`), so Postgres keeps its own default rather than deriving
one from the limit.

## 5. What deliberately did not change, and why

**Prometheus stays at 768Mi request / 1536Mi ceiling.** The 307Mi Civo reading
would justify cutting it. The 665Mi aws reading would not, and hetzner scrapes
more than either. Cutting the request to fit the floor is the exact failure the
Grafana comment already records — "the 400Mi request hid the real footprint
from the scheduler and so from the autoscaler". Taking a real measurement on
hetzner is the way to close this; no such run exists.

**Grafana stays at 640Mi request / 768Mi ceiling.** Measured 589Mi. The request
was raised to that figure on purpose so the autoscaler sees the footprint.

**Argo CD's controller stays at 768Mi / 1152Mi.** It was `OOMKilled` twice at
768Mi and raised for that reason.

**The PVC sizes and retention stay.** Cutting them was considered and dropped
on two findings. Hetzner's `hcloud-volumes` minimum is 10 GB and rounds a
smaller claim up (HETZ-160 §3), so a 5Gi claim would bill the same and save
nothing on the target where volumes cost most. And a StatefulSet's
`volumeClaimTemplates` are immutable, so a shrink wedges the Argo sync of any
cluster that is already running. The one profile is shared by aws, civo and
hetzner, so it has to satisfy the strictest of the three.

**No per-target override is added.** One set of numbers now holds every target.
A `hetzner` or `civo` key would be a second thing to keep true with no
measurement asking for it.

## 6. Acceptance criteria

| Criterion | Status |
|---|---|
| Every long-lived workload declares a CPU request, a memory request and a memory ceiling, or this spec states why not | pass, §4 and §5 |
| `make gitops-check`, `make scripts-check`, `make node-config-check`, `make specs-check` | pass |
| The aws golden render changes only in the three objects §4 names | pass — `Application__argocd__cert-manager`, `Cluster__cnpg-system__lab-postgres`, `Job__envoy__envoy-gateway-webhook-probe`, and nothing else |
| No pod is `OOMKilled` after the change | pass on hetzner — CI run 36044320545 brought a cluster up, passed `make test` and tore it down, with no `OOMKilled`, `CrashLoopBackOff` or container restart anywhere in its 7967-line log. That leg exercises the cert-manager, CNPG, Roles Anywhere sidecar and hcloud CCM changes. The envoy-gateway probe Job is aws-only and was not exercised |
| A hetzner Prometheus working-set reading, to settle §5 | outstanding — no spec owns it |

## 7. Risks

**The CNPG memory ceiling is new.** Postgres had none. A query that would
previously have taken the node down now kills the pod instead, which is the
intent, but 512Mi is a judgement and not a measurement — Postgres did not
appear among the top pods in the one reading that exists.

**The hcloud CCM cut is from a chart default, not from a measurement.** 100m
to 10m is a tenfold cut on a controller that has never been observed. The
platform sets no CPU ceiling anywhere, so the request cannot throttle it — only
contention with other pods can starve it. The failure mode is therefore a slow
taint removal rather than a hang, and it surfaces as `argo-up`'s
`wait_for_nodes_initialized` timing out while nodes still carry the
`uninitialized` taint.

## 8. Definition of done

- [x] Values changed, aws golden regenerated, every offline check green
- [x] CIVO-175 removed; HETZ-175 narrowed to the SKU fallback
- [x] Index rows and roadmaps updated
- [x] A live bring-up confirms no new `OOMKilled` (hetzner, CI run 36044320545)

## 9. Execution evidence and status history

- 2026-09-24 — created and implemented in one change, at the user's request to
  right-size once rather than per provider. CIVO-175 was deleted and the
  right-sizing half of HETZ-175 was removed from it. The two conflicting
  Prometheus readings were found during the work and are why §5 exists; without
  reconciling them, the largest number in the platform stays as it is.

- 2026-09-24 — the merge gate's hetzner leg ran the whole change on a real
  cluster: CI run 36044320545, `up`, `test` and `down` all green on `71f2cd6`.
  Nothing was `OOMKilled` and no container restarted, so the raised cert-manager
  ceilings, the new CNPG and sidecar ceilings, and the cut hcloud CCM request
  all hold on the one target that installs all four. The aws leg was skipped,
  so the envoy-gateway probe Job's new `resources` block is still unexercised
  on a live cluster; it renders correctly and the golden baseline covers it.
