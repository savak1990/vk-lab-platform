---
id: "HETZ-177"
title: "ARM node types (CAX) in the Hetzner catalogue, once they can be ordered"
status: "BLOCKED"
priority: "P1"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "The catalogue change is three lines; the work is finding out why the API offers a type it then refuses to create, and verifying every image the platform runs has an arm64 variant"
effort_estimate: "One session (3-4 h) plus one live Hetzner cycle, once unblocked"
estimate_confidence: "low"
depends_on: ["HETZ-040", "HETZ-045", "HETZ-182"]
blocked_by: []
supersedes: []
created: "2026-09-21"
updated: "2026-09-21"
completed: ""
---

# HETZ-177 — ARM node types in the Hetzner catalogue

> **Blocked on 2026-09-21, the day it was created.** Every CAX type is refused
> at creation on this account, in both usable locations, although the API
> advertises all of them as available and priced. Until that is resolved the
> catalogue must not offer them. §3 has the evidence; §6 step 0 is the work.

## 1. Outcome and rationale

`catalog.sh` offers Hetzner's CAX (Ampere arm64) server types alongside the x86
CX and CPX lines, and the platform is proven to run on them.

The case for it is cost, and the cost case is strong. Prices measured
2026-09-21 in `nbg1`, monthly, including the 0.726 EUR/mo primary IPv4:

| Type | Spec | EUR/mo | + IPv4 | 3-node cluster |
|---|---|---|---|---|
| `cax11` | 2c / 4g arm64 | 8.46 | 9.18 | 27.55 |
| `cax21` | 4c / 8g arm64 | 15.11 | 15.84 | **47.52** |
| `cax31` | 8c / 16g arm64 | 30.24 | 30.96 | 92.89 |
| `cpx32` | 4c / 8g x86 | 50.81 | 51.53 | **154.60** |
| `cpx42` | 8c / 16g x86 | 99.21 | 99.93 | 299.80 |

`cax31` is a larger machine than `cpx32` — twice the cores, twice the memory —
for 60% of the monthly price.

This matters against a specific number. `roadmap.md` sets M1's cost model at
**32 EUR fixed, 53 EUR ceiling**. A three-node `cax21` cluster costs 47.52 and
fits under the ceiling. The cheapest x86 cluster that could actually be created
on 2026-09-21 was `cpx32` at **154.60, about 3x over it**. So ARM is not a
cost optimization on this target; it is the difference between meeting the
milestone's own cost constraint and missing it threefold.

That is the prize. §3 is why it cannot be collected yet.

This does not replace HETZ-175. That spec picks a fallback when the chosen type
is out of stock; this one widens what can be chosen at all.

## 2. Scope and non-goals

In scope: finding out why CAX creation is refused and getting it unblocked; the
`hetzner` entries of `catalog_node_types` and `catalog_default_node_type`;
whatever `terraform/modules/hcloud-nodes` needs so `image = "ubuntu-24.04"`
resolves to the arm64 image; an audit of every container image the platform
runs on Hetzner for a `linux/arm64` variant; one live create/verify/destroy
cycle on `cax21`.

Out of scope: building the repo's own images for arm64 — that is HETZ-182.
Mixed-architecture clusters (§12.2). AWS and Civo: Civo sells no ARM, and the
AWS target already runs `t4g`/`m6g` Graviton, so the repo is not ARM-naive.

## 3. Current state / evidence

**The blocking finding.** Measured 2026-09-21 against the live API and by real
create attempts on the `vk-lab` account:

- `GET /v1/server_types` prices every CAX type in `fsn1`, `hel1` and `nbg1`,
  and reports `deprecation: null` for each.
- `GET /v1/datacenters` lists ids 45, 93, 94 and 95 (`cax11`, `cax21`, `cax31`,
  `cax41`) under **both** `server_types.available` **and**
  `server_types.supported` for `nbg1-dc3` and `hel1-dc2`.
- Creating any of them nevertheless fails:
  `hcloud: unsupported location for server type (invalid_input)`. Tried
  `cax11`, `cax21` and `cax31` in `nbg1`, and `cax11` in `hel1`. All refused.
- The failure is **not** the image. `cax11` was refused identically with
  `--image ubuntu-24.04` (by name) and with `--image 161547270` (the arm image
  id), so image resolution was never reached.
- Control: `cpx32` with the same flags in `nbg1` **created successfully** and
  was deleted. So the account, the SSH key, the labels and the CLI are fine.

**Conclusion: `datacenter.server_types.available` does not mean orderable.** It
was read as a stock signal when this spec was first drafted, and that reading
was wrong. Any future stock claim in this repo must come from a create attempt,
not from that field.

The cause is unknown. Candidates, none confirmed: an account- or
project-level entitlement for Ampere capacity; a regional sellout the
availability field lags behind; a CLI-to-API mapping problem for
`--location` on ARM types.

**Other state:**

- `scripts/lib/catalog.sh:95-97` lists x86 types only; `:115` makes `cx33` the
  default.
- `scripts/lib/require-valid-node-config.sh` refuses any type not in that list.
- `terraform/modules/hcloud-nodes/main.tf` sets `image = "ubuntu-24.04"`.
  Hetzner publishes **two** images under that one name: `161547269` (`x86`) and
  `161547270` (`arm`). Whether the provider picks by the server type's
  architecture is **still unproven** — the probe never got that far.
- The AWS target already runs arm64 (`catalog.sh:93`), so the gitops layer has
  met ARM before.
- k3s, the hcloud CCM, Argo CD and `cluster-autoscaler` all publish arm64
  images upstream. That is a claim to verify in §6, not to take on trust.

## 4. Design and contracts

Once unblocked:

- `catalog_node_types` gains `cax11 cax21 cax31` for `nbg1` and `hel1`.
  `cax41` is deliberately excluded: at 59.40 EUR/mo per node it exceeds the
  whole M1 cost ceiling with a single node, so offering it invites a cluster
  nobody intends to pay for. `fsn1` stays empty — it had no orderable type at
  all, ARM included.
- `catalog_default_node_type` for hetzner becomes `cax21`: same 4c/8g shape as
  today's `cx33`, and the cheapest type that meets the M1 cost model. This
  makes **arm64 the default architecture for the Hetzner target**, which is a
  larger commitment than widening the allowlist — every later spec (045's Argo
  CD, 115/120's CNPG, 160's observability) then meets ARM first rather than as
  an option. Taken knowingly; §6 step 1's image audit is what keeps it honest.
- The catalogue stays a flat allowlist with no architecture field. A Hetzner
  type name already implies its architecture (`cax` is ARM, `cx`/`cpx`/`ccx`
  are x86), and a second field would restate what the API carries.
- A cluster is single-architecture. `NODE_TYPE` applies to the control plane
  and every worker, and HETZ-170's autoscaler reuses the same worker template,
  so nothing produces a mixed cluster by accident (§12.2).
- No Terraform variable for architecture. If `image = "ubuntu-24.04"` does not
  resolve per architecture, the fix is a data source keyed on name **and**
  architecture, not an operator input.

## 5. Files/components affected

- `scripts/lib/catalog.sh` — the two hetzner cases.
- `terraform/modules/hcloud-nodes/main.tf` — only if the image lookup needs it.
- `specs/hetzner/decisions.md` — a row recording the default change and why.
- `specs/hetzner/README.md`, `roadmap.md` — this spec's row and edges.
- Possibly `gitops/` values, if a Hetzner-targeted chart pins an amd64-only
  image or sets a `nodeSelector` on `kubernetes.io/arch`.

## 6. Implementation steps

0. **Unblock creation.** Ask Hetzner support why `unsupported location for
   server type` is returned for a type the API prices and lists as available
   and supported in that exact datacenter, quoting one of the correlation ids
   in §14. Until a CAX server can be created by hand, nothing below runs and
   the catalogue must not offer the line.
1. Audit every image the Hetzner target runs for an arm64 variant: k3s, the
   hcloud CCM, Argo CD and its repo-server, Envoy Gateway, the observability
   set (Prometheus, Grafana, Loki, Tempo, Alloy, OTel Collector), CNPG,
   Strimzi, cert-manager, external-secrets, `cluster-autoscaler`. Record the
   manifest list or digest that proves each. Repo-built images are HETZ-182's.
2. Confirm the provider picks the arm image for an arm server type. Two images
   share the name `ubuntu-24.04` (§3); one real arm64 apply settles it.
3. Change the two `catalog.sh` cases. Run the node-config gate across every new
   type in both locations, and confirm `fsn1` still refuses them.
4. Bring up a `cax21` cluster and run HETZ-040's §8 checks against it
   unchanged.
5. Install the CCM and Argo CD (HETZ-045) and let the platform sync.
6. Record cost and boot time against the `cpx32` figures, and destroy.

## 7. Dependencies and blockers

Needs HETZ-040 (the scripts that bring a cluster up and prove it exists) and
HETZ-045 (the CCM, without which no node leaves the `uninitialized` taint).
Needs HETZ-182 for any repo-built image. **Blocked** on §6 step 0 — an
external answer, not repository work. Does not block M1.

## 8. Acceptance criteria

- A `cax21` server can be created on this account by hand.
- `NODE_TYPE=cax21 make cluster-up` passes the gate and brings up a cluster
  whose nodes all report `Ready`.
- `kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'`
  returns `arm64` for every node.
- No pod is in `ImagePullBackOff` or `CreateContainerError` with an
  `exec format error`, and none is `Pending` on a `kubernetes.io/arch`
  selector.
- HETZ-040's whole §8 list passes unchanged on that cluster.
- A recorded cost comparison against the same cluster shape on `cpx32`.
- `cax11`, `cax21` and `cax31` are accepted by the gate for `nbg1` and `hel1`,
  and all still refused for `fsn1`. `cax41` is refused everywhere.

## 9. Validation

`shellcheck` and `bash -n` on `catalog.sh`; the node-config gate across the
full provider/region/type matrix; `terraform validate`; one live
create/verify/destroy cycle on `cax21` (two nodes, about 0.03 EUR).

## 10. AWS regression protection

`catalog.sh`'s aws and civo cases are untouched. `make -n cluster-up
cluster-down status` on both must stay byte-identical, and the node-config gate
must accept and refuse exactly what it does today for them.

## 11. Rollout and rollback/recovery

Rollback is reverting the two `catalog.sh` cases. Nothing persists: an ARM
cluster is disposable, and `make down` leaves the same network, subnet and SSH
key an x86 cluster would.

## 12. Risks and unresolved questions

1. **CAX cannot be ordered at all on this account.** The blocking finding, §3.
   Everything else is downstream of it. If Hetzner's answer is that Ampere
   capacity is not available to this account, this spec closes as `Z` and the
   M1 cost model needs revisiting against x86 prices instead.
2. **Mixed-architecture clusters are deliberately unsupported.** They would
   need `nodeSelector` or affinity on every workload that is not multi-arch —
   a permanent tax to save cents. If ARM stock fails later, HETZ-175's fallback
   should prefer another ARM type before changing the whole cluster.
3. **An image with no arm64 variant.** Found in step 1, before any spend. The
   remedy is per image: an upstream tag that has one, or HETZ-182 for a
   repo-built one.
4. **Ampere cores are not Xeon cores.** The same core count is not the same
   throughput. SHARED-048 right-sizes on measured data; this spec should hand it
   ARM numbers rather than guess.

## 13. Definition of done

A CAX server can be created; the catalogue offers `cax11`/`cax21`/`cax31`; the
default is `cax21`; a real ARM cluster has passed HETZ-040's acceptance list
and carried Argo CD; and step 1's audit is written down here with step 6's cost
comparison.

## 14. Execution evidence and status history

- 2026-09-21 — created as DRAFT, out of a stock reading taken while setting up
  the HETZ-040 live test. That reading used
  `datacenter.server_types.available` and concluded all four CAX types were in
  stock in `nbg1` and `hel1` while every x86 type was not.
- 2026-09-21 — **moved to BLOCKED the same day; the reading was wrong.** Real
  create attempts refuse every CAX type in both locations with
  `unsupported location for server type (invalid_input)`, with and without an
  explicit arm image id, while `cpx32` creates normally with the same flags.
  Correlation ids: `5a130a89683b66b2f0293d3d3fc964b0` (`cax11` by name,
  `nbg1`), `d8b849a678bd897444e83cef327b1e0f` (`cax11` by arm image id,
  `nbg1`), `c06ff682fb738d040125454b58fc5951` (`cax11`, `hel1`),
  `7743c2cea3c002561132d11e72299436` (`cax21`, `nbg1`),
  `4e2205c441dcf4c0200dfcf7e33eab6a` (`cax31`, `nbg1`).
  A catalogue change adding the CAX line was written and **reverted unshipped**
  on the strength of this. The lesson generalises: in this repo, a stock claim
  must come from a create attempt, because the availability field advertises
  types the API then refuses.
- 2026-09-21 — `cax41` dropped from the proposed list on cost grounds: one node
  at 59.40 EUR/mo already exceeds the whole M1 ceiling.
