# ADR 0019: Avoid spot via anti-affinity instead of pinning to the system node; on-demand pool no longer Postgres-exclusive

## Status

Accepted

## Context

The observability rollout (spec 009) originally pinned Prometheus, Alertmanager, Grafana, Loki, and metrics-server
to the fixed system node via `nodeSelector: {node-type: system}`, to avoid the AZ-pinning/spot-interruption risk
a PVC-backed pod faces on Karpenter's `spot` pool. Argo CD itself carried no placement constraint at all.

In practice this pinning caused an outage on first rollout: the system node (`t4g.medium`) has a hard,
AWS-imposed ceiling of 17 pods (`3 ENIs × (6 IPv4/ENI − 1) + 2`, unrelated to CPU/memory), and baseline platform
pods (Argo CD's 7 + kube-system's 9 infra DaemonSets/Deployments + node-exporter) already consumed all 17 slots
before any observability pod was added. `nodeSelector: node-type: system` has exactly one possible home in the
whole cluster — Karpenter can never provision a node carrying that label (it's Terraform-only), so there was no
fallback and every pinned pod stayed `Pending` indefinitely.

Separately, the `on-demand` NodePool's taint (`dedicated=stateful:NoSchedule`, reserving it exclusively for
Postgres) had already been removed by the time this was diagnosed — Postgres now reaches that pool via a plain
node-label match (`workload-type`) instead of taint exclusivity, so nothing else was being kept off it by
mistake; it was simply never offered as a fallback to anything else either.

## Decision

1. Replace the hard `nodeSelector: node-type: system` on Prometheus, Alertmanager, Grafana, Loki, and
   metrics-server with a **hard node-affinity that only excludes `karpenter.sh/capacity-type: spot`**. This
   allows scheduling on the system node *or* the on-demand pool, while still avoiding spot's AZ-pinning hazard
   for the PVC-backed components. Add the same anti-spot affinity to Argo CD (`scripts/argo-up.sh`, via
   `global.affinity.nodeAffinity`), which previously had no placement constraint at all.
2. **Karpenter's own controller stays hard-pinned to `node-type: system`** — it is the one component whose job is
   to *manage* node capacity, so it must not depend on capacity it itself provisions.
3. **DaemonSets (Alloy, node-exporter) are exempted** and keep tolerating everything — their entire purpose is
   observing every node, spot included; excluding them from spot would blind the platform to exactly the nodes
   most likely to churn.
4. The `on-demand` pool's node label is renamed `workload-type: stateful` → `workload-type: on-demand`, and
   Postgres's `cluster.yaml` nodeSelector updated to match — the pool is no longer conceptually
   "Postgres-exclusive," so a label describing it as such was misleading now that other components share it.

## Consequences

- No single node's pod-count ceiling can starve the platform's own control plane or observability stack — a full
  system node now has a second real fallback destination (on-demand) for these components, and Karpenter can act
  on that fallback because the affinity it must satisfy is one it can actually provision for.
- The on-demand pool is no longer implicitly reserved for Postgres by cost intent — anything not excluded from it
  can now land there. This is a deliberate trade against the "keep everything off pricier on-demand capacity by
  default" cost framing `karpenter/nodepool.yaml` originally documented; the trade is judged worth it given the
  alternative (an unrecoverable `Pending` platform) is strictly worse.
- Increasing the system node's own pod-count ceiling (e.g. VPC CNI prefix delegation, or a larger instance type)
  was considered and deliberately not done — it would have fixed the specific 17-pod ceiling but not the
  single-point-of-failure shape of hard-pinning everything to one node, which is the more general problem this
  ADR actually addresses.
