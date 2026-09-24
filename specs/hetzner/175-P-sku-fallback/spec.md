---
id: "HETZ-175"
title: "Stock-aware SKU fallback when the chosen server type is out of stock"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "A Terraform variable and a failure path; the judgement is in which API error means what"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-24"
completed: ""
---

# HETZ-175 — SKU fallback

## 1. Outcome and rationale

`make cluster-up` on Hetzner fails fast with a clear message when the
chosen server type is out of stock, and the operator can switch to a
documented fallback with one variable.

Right-sizing was the other half of this spec. It moved to SHARED-048 on
2026-09-24 and shipped there, because the requests are shared values that
render for every target and one spec should own them.

The fallback exists because Hetzner limits CX and CAX stock since
2026-09-02 (`research.md`); a disposable cluster re-orders servers on
every `make up`, so a sold-out SKU turns `make up` into a failure.

## 2. Scope and non-goals

In scope: the operator-selected server type, the failure path when it is
out of stock, and the documented fallback table. Not in scope: the
autoscaler's node groups (HETZ-170 reads the same input),
mixed-architecture pools, and every request or limit, which is SHARED-048.

## 3. Current state / evidence

- HETZ-030 fixes `cx33` in `terraform/modules/hcloud-nodes`.
- `research.md` cost model: the ARM shape C 43.89 EUR; shape D (3 × CPX22) 70.89 EUR; shape E (3 × CX33) 37.89 EUR but sold out at the baseline date.
- All platform images are multi-arch (`research.md`), so an x86 fallback needs no image change.
- Hetzner's API reports per-location availability through `GET /v1/server_types` (`deprecation`) and `GET /v1/datacenters` (`server_types.available`); the `hcloud` CLI exposes it as `hcloud server-type describe <type>`.
- Neither availability field predicts a create, and neither MUST be used as a pre-flight signal. The per-datacenter `server_types.available` is wrong in both directions. Measured 2026-09-22 with real create calls: `cpx32` in fsn1 read `available=no` and created; `cax21` in nbg1 read `available=YES` and was refused. Datacenter targeting was deprecated on 2025-12-16 and the API now rejects the field, so those lists are no longer maintained. The per-type `server_types[].locations[].available` fails too: it read `false` for `cx33` in fsn1, nbg1 and hel1 on 2026-09-22, and a create succeeded in nbg1 and fsn1 the same day.
- The create endpoint returns two distinct errors, and only the first is about stock. `resource_unavailable` means a temporary shortage: `cx43` in nbg1 returned it and became orderable 20 minutes later on 2026-09-22. `unsupported location for server type` (`invalid_input`) means withdrawn from sale: every `cax` type, and the whole `cpx11`/`cpx21`/`cpx31`/`cpx41` generation, return it in every location.

## 4. Design and contracts

- `variable "server_type"` in `terraform/modules/hcloud-nodes`, default `cx33`, passed from `cluster-hetzner/k8s/terragrunt.hcl` via `HCLOUD_SERVER_TYPE` (operator input, like `PROJECT_NAME`). One server type for every node; mixed pools are out of scope.
- Fallback table, recorded in `research.md` and in this spec: `cx33` (default, x86, 8 GB) → `cpx32` (x86, 8 GB, 35.49 EUR each) → `cpx22` (x86, 4 GB, 19.49 EUR each); CAX types are listed only if a real create succeeds again, because ARM stock has not returned.
- Pre-flight in `scripts/cluster-up.sh` (hetzner branch): `hcloud datacenter list -o json` filtered to `nbg1`, check `server_types.available` contains the numeric id of `HCLOUD_SERVER_TYPE`; on failure print the fallback table and exit 2 before `terragrunt apply`.

## 5. Files/components affected

- `terraform/modules/hcloud-nodes/variables.tf`, `terraform/live/cluster-hetzner/k8s/terragrunt.hcl`.
- `Makefile` (`HCLOUD_SERVER_TYPE ?= cx33`, exported on hetzner only), `scripts/lib/provider.sh`.
- `scripts/cluster-up.sh` hetzner branch (pre-flight).
- `specs/hetzner/research.md` cost model and SKU table.

## 6. Implementation steps

1. Add the variable and the Make/provider plumbing; `terragrunt plan` shows no change with the default.
2. Add the pre-flight probe; test it with a type that does not exist (`cax99`) and with the current stock.
3. Update the cost model with measured allocatable memory and the volume price read from the invoice.

## 7. Dependencies and blockers

None. The right-sizing dependency left with the right-sizing scope.

## 8. Acceptance criteria

- `HCLOUD_SERVER_TYPE=cax99 PROVIDER=hetzner make cluster-up` exits 2 before any Terraform call, printing the fallback table.
- `HCLOUD_SERVER_TYPE=cpx32 PROVIDER=hetzner make cluster-up` creates a working x86 cluster; HETZ-130 tests pass on it.
- Default `make cluster-up` behaviour unchanged.
- `research.md` cost model updated with dated measured figures.

## 9. Validation

Offline: `terragrunt plan`, three-target render. Real cloud: one CPX32
cycle, about 0.15 EUR.

## 10. AWS regression protection

No AWS or Civo Terraform touched, and no shared values changed — this spec
now touches Hetzner Terraform and one shell branch only.

## 11. Rollout and rollback/recovery

Variable default and pre-flight are additive. A wrong request change is
reverted with one values commit.

## 12. Risks and unresolved questions

- The pre-flight design in §4 reads `server_types.available`, which §3 disproves. The probe must instead be built on the two create-time error codes, or dropped in favor of a clear failure message. Resolve this before implementation starts.
- `terraform apply` on a sold-out type fails with `resource_unavailable`; the script must surface that error with the fallback message. It must not surface `unsupported location for server type` the same way — that type is withdrawn, and a fallback table listing it wastes the operator's next attempt.
- Switching architecture between `make up` runs is safe for stateless workloads and for CNPG (the dump is architecture-neutral). A retained volume with an x86-specific filesystem quirk is not expected, and no spec owns that check.
- Mixed pools (ARM control plane, x86 workers) would let the autoscaler use whichever line is in stock; deferred.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-22 — create-call probes across every Hetzner location disproved `server_types.available` and separated the two error codes; recorded in §3, and §12 now flags the §4 probe design as unsound. `scripts/lib/catalog.sh` corrected: fsn1 was listed as having nothing orderable and in fact sells `cx23 cx33 cx43 cpx32 cpx42`. `research.md` corrected in the same change, where the fsn1 row and the proposed replacement probe field came from.
- 2026-09-22 — the Hetzner default location moved `nbg1` → `fsn1`, in six
  places that each carried it independently: `Makefile`, `scripts/lib/region.sh`,
  `catalog_default_region`, `terraform/live/root.hcl`, the `cluster-hetzner/k8s`
  terragrunt input and `hcloud-nodes`'s variable default. The reason is this
  spec's own earlier finding: the catalogue recorded fsn1 as having nothing
  orderable, create-call probes proved it sells five types, and every real
  cycle since has run there. The comment above `catalog_node_types` still
  asserted the old, disproved claim and is corrected in the same change.
  The state bucket name carries the region, so the change is safe by an
  existing guard rather than by luck: `scripts/state-up.sh:41-62` refuses a
  project that already holds state in another location and prints the
  teardown command. This does not advance the SKU fallback or the
  right-sizing work, so the spec stays `READY`.

- 2026-09-23 - this spec stopped being a nicety. HETZ-140's first Hetzner
  bring-up failed at placement on `cx33`, the Makefile default:
  `error during placement (resource_unavailable)` for the control plane and
  both workers. The API's datacenter listing showed no `cx` type (ids 114-117)
  available in any location, and `fsn1-dc14` with an empty availability list
  altogether. `cpx32` - the same 4 vCPU / 8 GiB - created in `fsn1` minutes
  later, so the flag was wrong in both directions in one reading, which
  `catalog.sh:63-65` already predicted. The CI leg pins `cpx32` by hand as a
  workaround; until the fallback here lands, every Hetzner run is one stock
  check away from being unable to start a cluster.

- 2026-09-24 — narrowed to the SKU fallback. The right-sizing half moved to
  SHARED-048 and shipped there: the requests are shared values rendered for
  every target, so one spec owns them rather than one per provider. This spec
  keeps its number because the fallback is unbuilt and still needed — on
  2026-09-24 a live read of `server_types[].locations[].available` showed
  `cx43` and `cx33` false in fsn1, nbg1 and hel1 and `cx23` true only in fsn1,
  so the shipped defaults cannot create a cluster and the CI leg still pins
  `cpx32` by hand. That field is not proof on its own — §3 records a create
  that succeeded against a `false` reading — which is why §12 says the probe
  must be built on the two create-time error codes.
