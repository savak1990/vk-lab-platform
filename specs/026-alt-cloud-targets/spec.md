# 026 — Alternative Cloud Execution Targets (Civo, DigitalOcean)

**Complexity:** High — not one hard problem, but every AWS-specific
integration point in specs 003–013 needs its own provider-gated branch, and
several have no drop-in equivalent at all.
**Risk:** Medium-High — the risk is not "Civo/DO don't work," it's silent
divergence from what the platform claims to provide (persistence, secrets,
credential hygiene) if a gap is papered over instead of stated.
**Estimated cost:** research/spec only for this document (~done). Full
implementation, if pursued later: ~1–2 weeks, comparable in shape to spec
021 but touching more specs (003–013, plus 015/017 for CI credentials).
**Recommended model:** Opus, for the ADR and cross-spec amendment pass;
Sonnet is fine for the mechanical Terraform module work once the design is
settled.
**Depends on:** architecture.md §10a (execution-target pattern), ADR 0006,
spec 021 (the `local` target — this spec reuses its structure, not a new
design). Constrains, rather than depends on, specs 003–013 the same way
spec 021 does.
**Lifecycle class(es) touched:** none by this document. A future
implementation would introduce `civo`/`do` disposable-lifecycle units
alongside the existing `aws` ones; persistent-lifecycle stays AWS-only
(Route 53/ACM/Secrets Manager have no reason to move).

## Motivation: cost

The trigger for this spec is cost, not a technical gap. EKS charges a flat
$0.10/hr ($73/mo) control-plane fee regardless of node count or activity —
Civo and DigitalOcean both offer a free control plane. At the platform's
current NodePool ceiling (system node fixed at 1, on-demand pool capped at
2 medium nodes, spot pool capped at 2 medium nodes — §9, 4 vCPU per pool ÷
2 vCPU/medium node), the worst case is 5 medium (2 vCPU/4GB, arm64) nodes
running 24/7:

| Item | AWS EKS | Civo | DigitalOcean |
|---|---|---|---|
| Control plane | $73.00/mo (flat, $0.10/hr) | $0 | $0 (HA tier +$40/mo, not needed here) |
| 5 × medium node (2 vCPU/4GB) | ~$107.60/mo (3 on-demand + 2 spot, blended) | ~$117.50/mo (5 × ~$23.50) | ~$120.00/mo (5 × $24.00) |
| Block storage (10Gi Postgres) | ~$0.80/mo | ~$1.00/mo | ~$1.00/mo |
| Load balancer | ~$16–22/mo (NLB) | ~$10/mo | ~$12–15/mo |
| Ancillary (CloudWatch/Secrets Mgr/KMS/Route 53) | ~$5.30/mo | n/a (no equivalent; Route 53 stays on AWS regardless) | n/a |
| **Total, 24/7 max capacity** | **~$205/mo** | **~$130/mo** | **~$135/mo** |
| **Savings vs. EKS** | — | **~$75/mo (37%)** | **~$70/mo (34%)** |

Node and LB pricing is close across all three — the entire delta is the
$73 control-plane fee AWS charges and the other two don't. At the
platform's actual, much lower duty cycle (`make down` between sessions),
the absolute dollar gap shrinks a lot, but the *shape* of the saving
(fixed EKS tax vs. none) is duty-cycle-independent and is the reason this
is worth a future look rather than a reason to act now.

## Scope

This spec is a **research and design document only**. It answers: is it
architecturally sound to add Civo and DigitalOcean as additional Argo CD
execution targets, reusing the existing `make persistent-up` → `make
cluster-up` → `make argo-up` command sequence unmodified? It does **not**
implement anything — no Makefile changes, no Terraform, no `gitops/` edits.
A future implementation spec would need its own architecture.md §10a
amendment and at least one ADR (see Open Questions) before code is written.

The premise this spec tests, and partially rejects, is "install everything
I have today without changes." That premise holds for the command surface
and for a meaningful chunk of the platform. It does not hold for the
AWS-native pieces — Karpenter's spot-fleet behavior, Pod Identity, Secrets
Manager, ACM/NLB TLS termination, and GitHub OIDC — which have no drop-in
equivalent and must be explicitly re-designed per target, the same way spec
021 explicitly re-designed them for `local` rather than silently omitting
them.

## Findings

### The command surface mostly survives, via a variable, not new commands

§21a is explicit that each lifecycle class gets exactly one create/destroy
command pair. `make civo-up` / `make do-up` / `make aws-up` alongside the
existing `make cluster-up` would violate that — three commands for one
lifecycle class, and `make cluster-up` orphaned. The existing precedent
(`PROJECT_NAME`/`REGION` env vars in `argo-up.sh`, `.Values.target` in
`gitops/`) is a `TARGET` variable, not a new command per provider:

```text
TARGET=civo make persistent-up   # still AWS: Route 53/ACM/Secrets Manager unaffected
TARGET=civo make cluster-up      # selects the civo Terragrunt unit instead of eks/
TARGET=civo make argo-up         # selects the civo kubeconfig + Helm target branch
```

`make persistent-up` is unaffected by `TARGET` in practice — Route 53,
ACM, and Secrets Manager stay on AWS regardless of where the cluster runs
(DNS just needs to point at whatever load balancer IP the new provider
hands back). This is the one part of "no changes" that holds exactly as
stated.

### `argo-up.sh` is mostly provider-agnostic, but three spots are not

Read in full for this spec. The Helm installs (Argo CD itself, the root
Application) take `--set target=...` and don't otherwise reference AWS.
Three concrete spots do:

1. `eks_output()` / `CLUSTER_NAME="$(eks_output cluster_name)"` — reads a
   Terragrunt output from the `disposable/eks` unit by path. A `civo`/`do`
   target needs the equivalent output from its own unit.
2. `aws eks update-kubeconfig` — needs a per-target branch:
   `civo kubernetes config <name> --save` /
   `doctl kubernetes cluster kubeconfig save <name>`.
3. The Postgres recovery-snapshot block (`aws ec2 describe-snapshots` /
   `delete-snapshot`, ADR 0013) — this entire mechanism is AWS-specific
   (EBS snapshots) and has no defined equivalent on either target yet (see
   Open Questions). Until one is designed, a `civo`/`do` target must either
   skip this block entirely (Postgres bootstraps fresh every time, like the
   `local` target) or fail closed rather than silently produce a
   `RECOVERY_SNAPSHOT_HANDLE` that means something different.

A fourth spot outside the discovery/kubeconfig logic: the Argo CD Helm
install sets a hard node-affinity anti-affinity against
`karpenter.sh/capacity-type=spot` — an AWS/Karpenter-specific label. A
`civo`/`do` target needs its own equivalent label or an explicit "no spot
avoidance" decision, not a silent no-op.

### What has a real equivalent

| AWS piece | Civo / DO equivalent | Notes |
|---|---|---|
| EKS cluster | Civo Kubernetes (k3s-based) / DOKS | Terraform providers exist (`civo/civo`, `digitalocean/digitalocean`) |
| Karpenter node provisioning | native node-pool min/max autoscaling (both providers) | no bin-packing, no spot-fleet diversification — see gaps below |
| AWS Load Balancer Controller → NLB | built-in cloud-controller-manager on `Service type=LoadBalancer` | no controller to install; ~$10–15/mo either provider |
| Route 53 / ACM | **unchanged — stays on AWS** | persistent-lifecycle, provider-independent |
| EBS gp3 volumes | Civo Volumes / DO Block Storage, both via CSI | dynamic provisioning path is equivalent |

### What has no equivalent — the real content of this spec

- **EKS Pod Identity + Secrets Manager + External Secrets Operator** — no
  Civo/DO counterpart exists. A `civo`/`do` target would need to fall back
  to the same placeholder-or-KMS-decrypt-into-plain-Secret pattern spec 021
  already defined for `local` (Requirements 11–13 there), not invent a
  third mechanism.
- **Karpenter's AWS-specific behavior** — spot-fleet capacity-optimized
  fallback across instance families/AZs, sub-minute bin-packing. Native
  autoscalers give min/max node counts, not this. Real capability loss,
  not just a naming difference.
- **ACM + NLB TLS termination** (architecture.md §11, invariant 10) — would
  become cert-manager + Let's Encrypt terminating at Envoy, or a
  provider-managed LB certificate. Either way, invariant 10 ("the NLB
  provides AWS ingress and TLS termination; Envoy owns all application
  traffic policy and routing") no longer holds verbatim for these targets —
  it needs its own stated variant, the same way `local`'s TLS story
  (Requirement 10, spec 021) is a separate, explicit divergence rather than
  a silent gap.
- **GitHub OIDC → temporary credentials** (constitution invariant 4,
  architecture §17) — Civo and DigitalOcean Terraform providers authenticate
  with a static API token; neither has an OIDC/STS-equivalent temporary
  credential mechanism. This is a direct conflict with a numbered platform
  invariant, not a missing feature — see Open Questions.
- **§39 resource tagging standard** — `Project`/`Scope`/`Lifecycle`/
  `ManagedBy` is an AWS-tag convention. Civo/DO have their own
  label/tag mechanisms with different constraints (Civo: no default-tags
  provider block equivalent found); parity needs its own check, not an
  assumption.

### Persistence — verify before relying on it

Constitution/architecture invariant 6 requires persistent data to survive
`make down`. ADR 0013's mechanism is a CSI `VolumeSnapshot`. DigitalOcean's
block-storage CSI driver supports `VolumeSnapshot`. Civo's CSI driver
(`civo/civo-csi`) appears to implement the `CREATE_DELETE_SNAPSHOT`
controller capability based on its own test suite, but this was not
confirmed against a running cluster for this spec — **treat as unverified**.
If Civo's snapshot support turns out to be absent or unreliable, a `civo`
target cannot satisfy invariant 6 and must be scoped as throwaway-only for
Postgres, the same way the `local` target is (spec 021, Requirement 6),
rather than silently claiming persistence it doesn't have.

## Open Questions (block implementation, not this spec)

1. **GitHub OIDC conflict** — does a future implementation spec (a) accept
   a static-API-token exception scoped explicitly to non-AWS targets via a
   new ADR, (b) restrict Civo/DO targets to workstation-initiated runs only
   (never GitHub Actions), or (c) find/wait for an OIDC-style mechanism from
   either provider? This needs an ADR before implementation starts.
2. **Civo VolumeSnapshot support** — confirm directly (a test cluster, not
   a search) before committing to persistence parity.
3. **TLS/edge architecture** — cert-manager+Envoy vs. provider-managed LB
   certificate, and how that interacts with invariant 10, needs its own
   ADR, mirroring ADR 0011's AWS-side NLB-vs-ALB decision.
4. Does a `civo`/`do` target's Postgres/Kafka story mirror `aws` (real
   persistence, pending Q2) or `local` (throwaway) more closely? This
   determines whether it's a third *real* lifecycle-bearing target or a
   third *disposable-only* target like `local`.

## Recommendation

Achievable for the command surface and for everything with a real
provider-native equivalent (cluster, load balancer, block storage). Not
achievable as literally "zero changes" for Pod Identity/Secrets
Manager/Karpenter/ACM+NLB/GitHub OIDC — those need explicit, documented
divergences per target, following the precedent architecture.md §10a and
spec 021 already established for `local`, not a retrofit that pretends
parity. Do not start implementation before Open Questions 1–2 are resolved.
