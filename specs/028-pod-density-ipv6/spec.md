# 028 — Pod density ceiling and IPv6 cluster networking

**Complexity:** High
**Risk:** Medium — a cluster-networking-mode change is not an in-place upgrade; a botched migration means recreating the disposable cluster.
**Estimated cost:** ~1–2 days, mostly validation (this is a lab-scale re-learning task, not large code).
**Recommended model:** Sonnet, with advisor consultation before touching NodePool/EC2NodeClass or the EKS module — networking-mode mistakes are expensive to unwind.
**Depends on:** 003 (network-and-eks), 006/006-1 (Karpenter), 009 (observability — the pod-count ceiling was discovered there).
**Lifecycle class(es) touched:** Disposable (EKS cluster, Karpenter-provisioned nodes). No Persistent-lifecycle resource is affected — VPC/subnets remain out of scope per spec 021 until that lands.

## Problem

Every node in this cluster is IPv4 VPC-CNI, which caps pods-per-node by ENI/secondary-IP count, not
CPU/memory. The ceiling is per-instance-type, not one universal number:

| Pool | Instance type | ENIs × IPv4/ENI | Ceiling (`ENIs×(IPv4/ENI−1)+2`) |
|---|---|---|---|
| System (Terraform) | `t4g.medium` | 3 × 6 | 17 |
| On-demand (Karpenter) | `t4g.medium` | 3 × 6 | 17 |
| Spot (Karpenter) | `m6g.medium` (observed live) | 2 × 4 | 8 |

This is not theoretical: it caused a real outage during the spec 009 observability rollout. Baseline
platform pods (Argo CD's 7 + kube-system's 10 infra DaemonSets/Deployments) already consumed all 17
slots on the system node before any observability pod was added. The fix shipped in ADR 0019
(anti-affinity that excludes `spot` instead of hard-pinning to the system node) works around the
ceiling by giving pods a second physical node to land on — it does not raise the ceiling itself, which
is still true of every node in the cluster today.

**Second occurrence, same spec 009 rollout:** even after ADR 0019's fix, the `alloy` and
`node-exporter` DaemonSets — which must run on every node, including a full one — stayed permanently
`Pending` on the system node, holding `kube-prometheus-stack`'s and `alloy`'s Argo Applications at
`Synced/Progressing` indefinitely. Kubernetes never evicted anything to make room: DaemonSet pods and
the existing system-node pods all run at default priority (0), and the scheduler only preempts a
*lower*-priority pod — equal-priority pods are never preemption victims
(`kubectl describe pod` showed `No preemption victims found for incoming pod`). A full node plus a
DaemonSet that must cover it is a standing deadlock, not a transient scheduling delay.

## Scope

Documents the pod-density ceiling as a standing constraint and records the long-term options to raise
it, for future implementation. **This spec does not implement anything yet** — it exists so the
problem and its trade-offs are captured once, instead of being re-discovered at the next density
crunch.

Excludes: any change to `terraform/live/disposable/eks`, Karpenter's `EC2NodeClass`/`NodePool`, or VPC
CNI config as part of *this* spec — those are the follow-up work an implementer picks from Option 1 or
4 below, done under its own PR once actually needed or chosen.

## Options considered (long-term fixes, none implemented yet)

ENIs and secondary IPs are free on AWS — only instance-hours cost money. That reframes the ranking:
prefix delegation and IPv6 both raise the ceiling at **zero additional AWS cost**; only the node-count
and instance-size options below actually cost more.

1. **VPC CNI prefix delegation + explicit `maxPods` override (recommended near-term fix — zero AWS
   cost).** `ENABLE_PREFIX_DELEGATION=true` on the `vpc-cni` addon gives each ENI slot a /28 (16 IPs)
   instead of 1 — on `t4g.medium` this raises the ceiling from 17 to `min(3×(6−1)×16+2, 110) = 110`
   (kubelet's own cap becomes the limit, not IP math). Two changes must land together or this silently
   no-ops: the addon's `configuration_values` (`ENABLE_PREFIX_DELEGATION`, `WARM_PREFIX_TARGET=1`), and
   kubelet `--max-pods` raised on *both* the Terraform-managed system node group and Karpenter's
   `EC2NodeClass.spec.kubelet.maxPods`. Verified 2026-08-25: the system node's subnet
   (`172.31.32.0/20`, the account's default-VPC public subnet used per spec 021's deferral) has 4,039
   free IPs — ample room for /28 reservations. Verification for whenever this lands: confirm
   `status.allocatable.pods` actually changed on a fresh node, not just that the addon config applied.
2. **IPv6 cluster networking (the long-term structural fix — also zero AWS cost).** EKS in IPv6 mode is
   not ENI/IPv4-count-limited the same way — pod density comes from a much larger address space instead
   of a per-ENI secondary-IP budget, and IPv6 egress needs only a free egress-only internet gateway, no
   paid NAT. This is the structurally correct fix, not a workaround, but it is a cluster-wide
   networking-mode decision: it touches the EKS cluster resource's IP family, the VPC/subnet CIDR
   allocation (relevant once spec 021 builds a dedicated VPC instead of relying on the account's
   default VPC), the VPC CNI config, and any hardcoded IPv4 assumption in Terraform modules or
   Kubernetes manifests. Not a retrofit onto a running cluster — implement as a fresh `make up` on a
   cluster created IPv6-native, not an in-place migration of the current one.
3. **Shrink the baseline pod count (cheapest, zero cost, but only a stopgap).** CoreDNS (an EKS managed
   addon — replica count is set via its `configuration_values`, a Terraform-owned surface, not a gitops
   Helm value) and the EBS CSI controller (Argo-managed, plain Helm value) both default to 2 replicas
   on a pool that is currently a single node, where HA buys nothing. Dropping either to 1 replica frees
   a slot per cut. Confirmed live 2026-08-25: this is exactly the fix that unblocked `alloy` and
   `node-exporter` DaemonSets stuck `Pending` on the full system node. Only recovers 1–2 slots, not
   headroom for real growth, and leaves zero margin — any future pod added to the system node re-wedges
   it.
4. **Add a second node to the system pool** (Terraform-managed node group `min/max/desired: 1 → 2`,
   same `t4g.medium`). Same 17-per-node ceiling, but 34 total slots for anything selecting
   `node-type: system`. One Terraform field, well-understood managed-node-group behavior, no CNI
   change — but it is a second always-on node, a real standing cost increase, which the constitution's
   cost-consciousness rule (§9) weighs against by default. **Costs money — not a fit for a zero-cost
   ask.**
5. **Upsize the node's instance type** (e.g. `t4g.medium`→`t4g.large`, or the observed spot pool's
   `m6g.medium`→`m6g.large`: 2×4 IPs/8-pod ceiling → 3×10 IPs/29-pod ceiling). Raises the ceiling via a
   bigger IP budget, but roughly doubles that node's hourly cost. **Costs money — not a fit for a
   zero-cost ask.**

## Recommendation

For the immediate, real ceiling (not just a stopgap): **prefix delegation (option 1)** — zero AWS cost,
raises the actual ceiling by 6x+ on the same instance type, no cluster recreate. For the long-term
direction: **IPv6 (option 2)** — removes the ceiling as a class of problem rather than raising it by a
fixed multiple, also zero AWS cost, and the option the user has specifically flagged as a wanted future
task; it's a bigger networking-mode change than prefix delegation so it stays the later task. Option 3
(replica shrink) is the correct 5-minute stopgap when observability needs to go green *today*, not the
fix. Options 4 and 5 are ruled out whenever cost matters, since instance-hours are the one thing that
actually gets billed here.

## Implementation hints (for whenever this is picked up)

- IPv6 EKS clusters still run dual-stack at the control-plane/service level in most configurations —
  read current AWS EKS IPv6 documentation before assuming a specific mode; this spec intentionally does
  not pin exact API fields since EKS IPv6 support has evolved.
- Coordinate with spec 021 (VPC): building the dedicated VPC IPv6-native from the start avoids a second
  migration later.
- Re-verify Karpenter's `EC2NodeClass`/`NodePool` IPv6 support and the VPC CNI's IPv6 mode compatibility
  with the exact chart/addon versions in use at implementation time — don't assume parity with IPv4 mode.
- Treat this as a full recreate: stand up a new disposable cluster IPv6-native, validate, then tear down
  the old one — not an in-place flip of cluster networking mode.

## Testing / acceptance criteria (for whenever this is picked up)

- A fresh `make up` on the IPv6-native cluster reaches Synced/Healthy with the same platform components
  as today, with no `nodeSelector`/anti-affinity workaround needed to fit baseline pods.
- `kubectl get nodes -o wide` and a pod-count check confirm the per-node pod ceiling is no longer
  bound by the IPv4 ENI/secondary-IP formula.
- Full lifecycle acceptance test (per project CLAUDE.md) still passes end-to-end on the new networking
  mode: `make up` → verify → write persistent data → `make down` → verify persistence → `make up` →
  verify recovery.

## Record

Filed 2026-08-25, prompted by the pod-density outage during the spec 009 observability rollout (see
ADR 0019 for the incident and the interim anti-affinity fix). Same day, same rollout: the ceiling
recurred as `alloy`/`node-exporter` DaemonSets stuck `Pending` on the now-full system node, with no
scheduler preemption to resolve it (see Problem section) — options re-ranked afterward by actual AWS
cost rather than engineering complexity. No ADR filed yet — file one if/when an option here is
actually implemented, recording which was chosen and why.
