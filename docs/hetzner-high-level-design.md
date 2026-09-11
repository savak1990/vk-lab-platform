# Hetzner as a third provider — high-level design

**Status:** Living design document. Decisions below are dated; the detailed
planning package is `specs/hetzner/` (start at `specs/hetzner/README.md`).
**Inspected baseline:** branch `civo-115-cnpg-cluster-on-civo`, 2026-09-11.

This document explains *why* the platform adds Hetzner and what makes it
different from Civo. It does not repeat the shared non-EKS design
(`docs/civo-high-level-design.md`) or the task breakdown
(`specs/hetzner/`). Read those for the stage model, the identity chain,
and the persistence flow, which Hetzner reuses without change.

## 1. Why Hetzner

The AWS target proves the platform on production-grade managed services.
The Civo target proves the platform on a second, cheaper managed
Kubernetes. Hetzner tests a third, harder case: **no managed Kubernetes at
all, and a materially different price-to-resource ratio**. For a personal
lab whose goal is the most CPU and memory for 50–100 USD a month, that
ratio matters more than convenience.

Hetzner Cloud sells servers, private networks, firewalls, load balancers
and block volumes over one API, at prices below both EKS and Civo — on
its ARM line. It sells no Kubernetes product. Adding it forces the
platform to answer a question the other two targets let it avoid: what
does "Terraform owns the cloud, Argo CD owns the cluster" mean when there
is no cluster until the platform creates one?

## 2. Pricing: what actually changed

Hetzner's headline reputation ("much cheaper than AWS or Civo") needed
correction before any design work. Two 2026 price increases and a stock
shortage move the real numbers:

- **1 April 2026**: every product, including running subscriptions, rose
  roughly 30–37% (load balancer 5.39 → 7.49 EUR/month; Object Storage base
  4.99 → 6.49 EUR/month).
- **15 June 2026**: cloud servers rose again, on new orders and rescales
  only. The CX (Intel) and CAX (ARM) lines rose 30–40%; the CPX (AMD) and
  CCX (dedicated) lines rose 2.4–2.75×. A disposable lab cluster places a
  **new order every `make up`**, so it always pays the current price, not
  a legacy rate.
- **Since 2 September 2026**, the CX and CAX lines are stock-limited.
  CX33–CX53 are sold out in every EU location at the baseline date; CAX
  stays available.

Net effect: **only the ARM (CAX) line still beats Civo materially.** Three
`cax21` servers (4 vCPU / 8 GB each) cost about 44 EUR/month all-in
(nodes, load balancer, primary IPs, volumes) for roughly 21 GiB of
allocatable memory. Civo's three-Medium-node plan costs 80.67 USD (Civo
prices in USD natively) for 6.8 GiB. The x86 fallback (CPX22) costs about
71 EUR — close to Civo's price in absolute terms, for less memory — it
exists only as a hedge against CAX stock-outs, not as the target shape.
Full table and sources: `specs/hetzner/research.md`.

| | Civo (3 Medium) | Hetzner ARM (3 × CAX21) | Hetzner x86 fallback (3 × CPX22) |
|---|---|---|---|
| Monthly cost, all-in (native currency) | 80.67 USD | ~44 EUR | ~71 EUR |
| Allocatable memory | 6.8 GiB | ~21 GiB | ~9.6 GiB |
| Kubernetes | managed | self-bootstrapped k3s | self-bootstrapped k3s |
| Reserved/stable LB IP | yes | no (new IP each `make up`) | no |

Civo and Hetzner price in different currencies (USD vs. EUR); the table
gives each in its own currency rather than a fabricated conversion. As one
reference point, Hetzner's own published USD price for `cax21` is 12.49
USD/node — about 50 USD/month for the three-node total before the load
balancer, IPs and volumes.

The lab's stated goal — maximize CPU/memory for 50–100 USD/month — is met
only by the ARM shape, and only while CAX stays in stock. `HETZ-175`
exists specifically to fail fast and fall back to x86 when it does not.

## 3. Why this is materially harder than Civo

Civo added one axis: a second managed Kubernetes provider with its own
annotations and CLI. Hetzner adds two:

1. **No managed control plane.** The platform must create it, keep it
   running, and retrieve credentials for it, none of which Civo required.
2. **No preinstalled cluster controllers.** Civo ships its own cloud
   controller manager, CSI driver and default StorageClass. Hetzner ships
   none of them; the bootstrap script installs the cloud controller
   manager, and Argo CD then installs the CSI driver and its
   StorageClass.

Three consequences follow directly, and none has a Civo precedent:

- **Bootstrap ordering.** A k3s node started with
  `--kubelet-arg cloud-provider=external` carries the taint
  `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` until the
  Hetzner cloud controller manager (CCM) sets its `providerID`. k3s's own
  bundled CoreDNS does not tolerate that taint, so a freshly booted
  cluster has no cluster DNS. Argo CD therefore cannot be the thing that
  installs the CCM — it would need DNS to reach its own repo server and
  GitHub, and it has none. The `argo-up` script must helm-install the CCM
  itself, before Argo CD, in the same untracked-bootstrap class the
  script already uses for Argo CD's own installation.
- **No kubeconfig API.** Civo's CLI hands back a kubeconfig with one
  command. No Hetzner API does this for a self-managed cluster; the only
  paths are SSH to the control-plane node or minting a client certificate
  locally from a pre-generated k3s CA. The platform uses SSH with a
  KMS-encrypted key, matching the pattern already used for the CA
  ceremony.
- **Teardown does not cascade.** Civo deletes a cluster's load balancer
  and reaps its resources as part of `civo kubernetes remove`. Hetzner's
  load balancer, volumes and primary IPs are independent resources that
  outlive server deletion and keep billing. Every teardown path — CI
  cleanup, `cluster-down`, the autoscaler — must sweep them by label
  instead of relying on "delete the cluster."

Everything above the Kubernetes API is, by contrast, easier than it
sounds: Envoy Gateway, cert-manager, ExternalDNS, External Secrets,
CloudNativePG, and the Roles Anywhere identity chain are the same
components Civo already proved, reused through two small generalisation
specs (`HETZ-016`, `HETZ-018`) that turn Civo-specific branches into
non-AWS or per-provider ones. Hetzner does not redesign the platform; it
extends the one part of the design — "how does a workload reach AWS
without a permanent key" — that already generalizes, and rebuilds the one
part — "how does Kubernetes come to exist" — that Civo's managed offering
had hidden.

## 4. What does not carry over from Civo

| Civo behavior | Hetzner reality |
|---|---|
| Managed Kubernetes, CCM/CSI preinstalled | Self-bootstrapped k3s; CCM and CSI both absent, both must be installed |
| `civo kubernetes config` returns a kubeconfig | No equivalent API; SSH with a KMS-encrypted key |
| Reserved IP keeps the load balancer's address stable | Primary IPs attach to servers only, not load balancers; the LB gets a new address every `make up`; DNS-01 wildcard TLS is used instead of HTTP-01 to avoid depending on a fixed address |
| Cluster deletion reaps its load balancer | The LB, volumes, and primary IPs are independent resources; teardown must sweep them by label |
| One API token, used only outside the cluster | The Hetzner token must also live in-cluster (`kube-system/hcloud`) for the CCM and CSI driver — a materially larger blast radius, mitigated by a dedicated per-project token |
| No architecture concern (Civo images are whatever Civo runs) | Every platform image must be proven arm64; only the repository's own `pg-backup` image needed a multi-arch rebuild (`HETZ-182`) |

## 5. Where things live

- Task breakdown, dependency graph, milestones: `specs/hetzner/README.md`, `roadmap.md`.
- Coupling inventory (what each Civo spec becomes on Hetzner): `specs/hetzner/architecture.md`.
- Verified capabilities, prices, uncertainties: `specs/hetzner/research.md`.
- Decisions and proposed ADRs: `specs/hetzner/decisions.md`.
- The shared non-EKS design this package extends: `docs/civo-high-level-design.md`.
