---
id: "HETZ-175"
title: "Stock-aware SKU fallback (CAX to CPX) and right-sizing on measured data"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "A Terraform variable, a pre-flight probe and a measurement exercise; the judgement is in reading the Prometheus data"
effort_estimate: "Half a session (2–3 h) plus seven days of metrics"
estimate_confidence: "medium"
depends_on: ["HETZ-160", "CIVO-175"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-175 — SKU fallback and right-sizing

## 1. Outcome and rationale

`make cluster-up` on Hetzner fails fast with a clear message when the
chosen server type is out of stock in `nbg1`, and the operator can switch
to a documented x86 fallback with one variable. After seven days of
Prometheus data the shared requests and limits are adjusted for the CAX21
node size, and the cost model is updated with measured figures.

The fallback exists because Hetzner limits CX and CAX stock since
2026-09-02 (`research.md`); a disposable cluster re-orders servers on
every `make up`, so a sold-out SKU turns `make up` into a failure.

## 2. Scope and non-goals

In scope: `server_type` as a Terraform variable, the pre-flight
availability probe, the documented fallback table, and the right-sizing
pass. Not in scope: the autoscaler's node groups (HETZ-170 reads the same
variable), mixed-architecture pools, and any Civo or AWS request change
that CIVO-175 does not already make.

## 3. Current state / evidence

- HETZ-030 fixes `cax21` in `modules/hcloud-k3s`.
- `research.md` cost model: shape C (3 × CAX21) 43.89 EUR; shape D (3 × CPX22) 70.89 EUR; shape E (3 × CX33) 37.89 EUR but sold out at the baseline date.
- All platform images are multi-arch (`research.md`), so an x86 fallback needs no image change.
- Hetzner's API reports per-location availability through `GET /v1/server_types` (`deprecation`) and `GET /v1/datacenters` (`server_types.available`); the `hcloud` CLI exposes it as `hcloud server-type describe <type>`.
- CIVO-175 defines the measurement method (seven days, `container_memory_working_set_bytes` p95 and CPU p95 per workload).

## 4. Design and contracts

- `variable "server_type"` in `modules/hcloud-k3s`, default `cax21`, passed from `cluster-hetzner/k8s/terragrunt.hcl` via `HCLOUD_SERVER_TYPE` (operator input, like `PROJECT_NAME`). One type for all three nodes; mixed pools are out of scope.
- Fallback table, recorded in `research.md` and in this spec: `cax21` (default, ARM, 8 GB) → `cpx32` (x86, 8 GB, 35.49 EUR each) → `cpx22` (x86, 4 GB, 19.49 EUR each). CX types are listed only as opportunistic (`cx33`) because their stock is unreliable.
- Pre-flight in `scripts/cluster-up.sh` (hetzner branch): `hcloud datacenter list -o json` filtered to `nbg1`, check `server_types.available` contains the numeric id of `HCLOUD_SERVER_TYPE`; on failure print the fallback table and exit 2 before `terragrunt apply`.
- Right-sizing: the same values keys as CIVO-175 (`observability.*.resources`, `postgres.resources`, ESO, ExternalDNS, Envoy), adjusted from measured p95 with the CIVO-175 headroom rule, and a per-target override only where CAX21 differs from Civo Medium.

## 5. Files/components affected

- `terraform/modules/hcloud-k3s/variables.tf`, `terraform/live/cluster-hetzner/k8s/terragrunt.hcl`.
- `Makefile` (`HCLOUD_SERVER_TYPE ?= cax21`, exported on hetzner only), `scripts/lib/provider.sh`.
- `scripts/cluster-up.sh` hetzner branch (pre-flight).
- `gitops/values.yaml` (measured requests/limits; hetzner overrides).
- `specs/hetzner/research.md` cost model and SKU table.

## 6. Implementation steps

1. Add the variable and the Make/provider plumbing; `terragrunt plan` shows no change with the default.
2. Add the pre-flight probe; test it with a type that does not exist (`cax99`) and with the current stock.
3. Run seven days with the HETZ-160 stack; export p95 per workload.
4. Apply the CIVO-175 rule; render three targets; confirm aws and civo renders change only where CIVO-175 changed them.
5. Update the cost model with measured allocatable memory and the volume price read from the invoice.

## 7. Dependencies and blockers

HETZ-160 supplies the metrics. CIVO-175 supplies the method and the shared
values changes; this spec does not repeat them.

## 8. Acceptance criteria

- `HCLOUD_SERVER_TYPE=cax99 PROVIDER=hetzner make cluster-up` exits 2 before any Terraform call, printing the fallback table.
- `HCLOUD_SERVER_TYPE=cpx32 PROVIDER=hetzner make cluster-up` creates a working x86 cluster; HETZ-130 tests pass on it.
- Default `make cluster-up` behaviour unchanged.
- Requests and limits recorded with the measurement window and the p95 figures; no pod is `OOMKilled` in the following 24 h.
- `research.md` cost model updated with dated measured figures.

## 9. Validation

Offline: `terragrunt plan`, three-target render. Real cloud: one CPX32
cycle (about 0.15 EUR) and the seven-day measurement on the running lab.

## 10. AWS regression protection

No AWS or Civo Terraform touched. Shared values changes are those of
CIVO-175; hetzner-only overrides live under a `hetzner` key that the aws
and civo renders never read. Golden renders for both confirm.

## 11. Rollout and rollback/recovery

Variable default and pre-flight are additive. A wrong request change is
reverted with one values commit.

## 12. Risks and unresolved questions

- Hetzner's availability field lags stock changes by minutes; the probe reduces failures but cannot remove them. `terraform apply` on a sold-out type fails with `resource_unavailable`; the script must surface that error with the same fallback message.
- Switching architecture between `make up` runs is safe for stateless workloads and for CNPG (the dump is architecture-neutral), but a retained volume with an x86-specific filesystem quirk is not expected; note it in HETZ-150 if seen.
- Mixed pools (ARM control plane, x86 workers) would let the autoscaler use whichever line is in stock; deferred.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Cost model updated with measured figures
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
