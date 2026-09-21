---
id: "HETZ-177"
title: "ARM node types (CAX) in the Hetzner catalogue, verified end to end"
status: "DRAFT"
priority: "P1"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "The catalogue change is three lines; the work is verifying every controller and image the platform runs has an arm64 variant, and proving a real cluster comes up"
effort_estimate: "One session (3-4 h) plus one live Hetzner cycle"
estimate_confidence: "medium"
depends_on: ["HETZ-040", "HETZ-045", "HETZ-182"]
blocked_by: []
supersedes: []
created: "2026-09-21"
updated: "2026-09-21"
completed: ""
---

# HETZ-177 — ARM node types in the Hetzner catalogue

## 1. Outcome and rationale

`catalog.sh` offers Hetzner's CAX (Ampere ARM64) server types alongside the
x86 CX and CPX lines, and the platform is proven to run on them.

Two measurements drive this, both taken 2026-09-21 against the live API:

| Type | Spec | EUR/h | nbg1 | hel1 |
|---|---|---|---|---|
| `cx33` | 4c / 8g x86 | 0.0194 | out of stock | out of stock |
| `cpx31` | 4c / 8g x86 | 0.0397 | out of stock | out of stock |
| `cpx32` | 4c / 8g x86 | 0.0814 | in stock | in stock |
| `cax21` | 4c / 8g **arm64** | **0.0242** | **in stock** | **in stock** |

First: **price.** `cax21` is 3.4x cheaper than the only in-stock x86 type of
the same size. The constitution ranks low cost above simplicity, and this is
not a marginal difference.

Second: **stock.** Every x86 type in the catalogue was unorderable in both
usable locations on that date, including `cx33`, which is
`catalog_default_node_type`. A plain `make cluster-up` therefore fails inside
`terragrunt apply` with a Hetzner availability error. The CAX line was
orderable in both. ARM is not only the cheap option here, it is the available
one.

This does not replace HETZ-175. That spec picks a fallback when the chosen
type is out of stock; this one widens what can be chosen at all. They compose:
a stock-aware fallback is worth more with a line that is usually in stock.

## 2. Scope and non-goals

In scope: the `hetzner` entries of `catalog_node_types` and
`catalog_default_node_type`; whatever `terraform/modules/hcloud-nodes` needs
so `image = "ubuntu-24.04"` resolves to the arm64 image; an audit of every
container image the platform runs on Hetzner for an `linux/arm64` variant; one
live create/verify/destroy cycle on `cax21`.

Out of scope: building the repo's own images for arm64 — that is HETZ-182, and
this spec depends on it rather than duplicating it. Mixed-architecture
clusters (see §12). AWS and Civo, which are untouched: Civo sells no ARM and
the AWS target already runs `t4g`/`m6g` Graviton, so the repo is not
ARM-naive.

## 3. Current state / evidence

- `scripts/lib/catalog.sh:95-97` lists x86 types only: `nbg1` gets
  `cx23 cx33 cx43 cx53 cpx32 cpx42`, `hel1` a subset, `fsn1` nothing.
  `:113` makes `cx33` the default.
- `scripts/lib/require-valid-node-config.sh` refuses any type not in that
  list, so `NODE_TYPE=cax21` is rejected before Terraform runs.
- `terraform/modules/hcloud-nodes/main.tf` sets `image = "ubuntu-24.04"` for
  every server. Hetzner publishes that name for both architectures and the API
  selects by the server type's architecture; **this needs confirming, not
  assuming** — the provider may resolve the name to a fixed image id.
- The AWS target already runs arm64 (`catalog.sh:93`: `t4g.medium t4g.large
  m6g.large`), so the gitops layer has met ARM before.
- HETZ-182 (`DRAFT`, P0) publishes repo-built images for `linux/arm64`.
- k3s, the hcloud cloud controller manager, Argo CD and
  `cluster-autoscaler` all publish arm64 images upstream. That is the claim to
  verify in §6, not to take on trust.

## 4. Design and contracts

- `catalog_node_types` gains the CAX line for `nbg1` and `hel1`:
  `cax11 cax21 cax31 cax41`. `fsn1` stays empty — it had no types at all.
- `catalog_default_node_type` for hetzner becomes `cax21`: 4c/8g, the same
  shape as today's `cx33` default, at a quarter more cost but actually
  orderable.
- The catalogue stays a flat allowlist. It does **not** gain an architecture
  field. A type name already implies its architecture on Hetzner (`cax` is
  ARM, `cx`/`cpx`/`ccx` are x86), and a second field would be a fact the API
  already carries.
- A cluster is single-architecture. `NODE_TYPE` applies to the control plane
  and every worker, and HETZ-170's autoscaler reuses the same worker template,
  so nothing can produce a mixed cluster by accident. §12 records why that is
  the boundary.
- No Terraform variable for architecture. If `image = "ubuntu-24.04"` does not
  resolve per architecture, the fix is to look the image up by name **and**
  architecture in a data source, not to add an operator input.

## 5. Files/components affected

- `scripts/lib/catalog.sh` — the two hetzner cases.
- `terraform/modules/hcloud-nodes/main.tf` — only if the image lookup needs it.
- `specs/hetzner/decisions.md` — a row recording the default change and why.
- `specs/hetzner/README.md`, `roadmap.md` — this spec's row and edges.
- Possibly `gitops/` values, if any Hetzner-targeted chart pins an
  amd64-only image or sets a `nodeSelector` on `kubernetes.io/arch`.

## 6. Implementation steps

1. Audit every image the Hetzner target runs for an arm64 variant: k3s itself,
   the hcloud CCM, Argo CD and its repo-server, Envoy Gateway, the
   observability set (Prometheus, Grafana, Loki, Tempo, Alloy, OTel
   Collector), CNPG, Strimzi, cert-manager, external-secrets, and
   `cluster-autoscaler`. Record each digest or the manifest list that proves
   it. Anything repo-built is HETZ-182's, and blocks only that image.
2. Confirm how `image = "ubuntu-24.04"` resolves for an arm64 server type.
   Create one `cax11` by hand with the CLI first — it is the cheapest thing
   Hetzner sells — and read back the image id.
3. Change the two `catalog.sh` cases. Run the node-config gate for every new
   type in both locations.
4. Bring up a `cax21` cluster (HETZ-040's `make cluster-up`), and run
   HETZ-040's §8 checks against it unchanged.
5. Install the CCM and Argo CD (HETZ-045) and let the platform sync.
6. Record cost and boot time against the `cpx32` figures, and destroy.

## 7. Dependencies and blockers

Needs HETZ-040 (the scripts that bring a cluster up and prove it exists) and
HETZ-045 (the CCM, without which no node leaves the `uninitialized` taint).
Needs HETZ-182 for any image this repo builds itself. Does not block M1.

## 8. Acceptance criteria

- `NODE_TYPE=cax21 make cluster-up` passes the node-config gate and brings up
  a cluster whose nodes all report `Ready`.
- `kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'`
  returns `arm64` for every node.
- No pod on the cluster is in `ImagePullBackOff` or
  `CreateContainerError` with an `exec format error`, and none is `Pending`
  on an `kubernetes.io/arch` node selector.
- The whole HETZ-040 §8 list passes unchanged on this cluster.
- A recorded cost comparison against the same cluster shape on `cpx32`.
- `cax11`, `cax21`, `cax31` and `cax41` are all accepted by the gate for
  `nbg1` and `hel1`, and all still refused for `fsn1`.

## 9. Validation

`shellcheck` and `bash -n` on `catalog.sh`; the node-config gate across the
full matrix of provider, region and type; `terraform validate`; one live
create/verify/destroy cycle on `cax21` (two nodes, about 0.05 EUR).

## 10. AWS regression protection

`catalog.sh`'s aws and civo cases are untouched. `make -n cluster-up
cluster-down status` on both must stay byte-identical, and the node-config
gate must still accept and refuse exactly what it does today for them.

## 11. Rollout and rollback/recovery

Rollback is reverting the two `catalog.sh` cases. Nothing persists: an ARM
cluster is disposable, and a `make down` leaves the same network, subnet and
SSH key an x86 cluster would.

## 12. Risks and unresolved questions

1. **An image with no arm64 variant.** Found in step 1, before any spend. The
   remedy is per image: an upstream tag that has one, or HETZ-182 for a
   repo-built one. If a component has no arm64 build at all, that component —
   not this spec — decides the outcome.
2. **Mixed-architecture clusters are deliberately not supported.** They would
   need `nodeSelector` or affinity on every workload that is not multi-arch,
   which is a large, permanent tax to save a few cents. If ARM stock ever
   fails the way x86 stock did, HETZ-175's fallback should pick another ARM
   type first, and only then change the whole cluster.
3. **Ampere cores are not Xeon cores.** Same core count is not the same
   throughput. HETZ-175 right-sizes on measured data; this spec should hand it
   the ARM numbers rather than guess.
4. **Stock can move the other way.** The 2026-09-21 measurement is one
   reading, not a guarantee. The point of this spec is that the catalogue
   should hold both lines, so whichever is orderable can be chosen.

## 13. Definition of done

The catalogue offers the CAX line, the default is `cax21`, a real ARM cluster
has run the HETZ-040 acceptance list and carried Argo CD, and the audit from
step 1 is written down in this spec with the cost comparison from step 6.

## 14. Execution evidence and status history

- 2026-09-21 — created as DRAFT, out of the stock measurement taken while
  testing HETZ-040. Every x86 type in the catalogue was out of stock in both
  usable Hetzner locations, including the default `cx33`; `cax21` was in stock
  in both at 0.0242 EUR/h against `cpx32`'s 0.0814 for the same 4 cores and
  8 GB. ARM was passed over for that test only because changing the catalogue
  inside the HETZ-040 PR would have mixed two concerns, not because anything
  is known to be wrong with it.
