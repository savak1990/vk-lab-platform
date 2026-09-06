---
id: "CIVO-150"
title: "Full lifecycle validation on Civo: create, write, destroy, verify, recreate, verify, destroy, no leaks"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "validation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Judging leak and persistence evidence across two providers' resource models needs careful review"
effort_estimate: "One session (4–6 h wall clock, mostly waiting)"
estimate_confidence: "medium"
depends_on: ["CIVO-120", "CIVO-110", "CIVO-070", "CIVO-130"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-150 — Lifecycle validation

## 1. Outcome and rationale

The constitution §11 acceptance test passes on Civo end to end with
recorded evidence, and a resource classification table with owner and
destroy/retain policy exists for every Civo and AWS resource the target
uses.

## 2. Scope and non-goals

In scope: the runbook `tests/manual/civo-150-lifecycle.md`, execution,
evidence, classification table, leak checks, cost record. Not in scope:
code changes beyond small fixes discovered (those go to the owning spec).

## 3. Current state / evidence

Existing AWS runbooks under `tests/manual/`; `argo-down.sh` gates; the
`cluster-down.sh` leak sweep pattern.

## 4. Design and contracts

Classification table (filled during execution):

| Resource | Lifecycle | Owner | On `argo-down` | On `cluster-down` | On `persistent-down` | On `bootstrap-down` |
|---|---|---|---|---|---|---|
| Civo LB | cluster | CCM via Envoy Service | deleted (gate) | must be absent | — | — |
| Civo volumes (CNPG, observability) | cluster (Delete class) / persistent artifact | CSI / scripts | snapshot or retain per 120 | deleted or retained | artifacts deleted | — |
| Civo snapshots | persistent artifact | scripts | created, pruned to 2 | untouched | deleted | — |
| Civo cluster, firewall | cluster | Terraform | — | destroyed | — | — |
| Civo network, reserved IP | persistent | Terraform | — | untouched | destroyed | — |
| Route 53 records | cluster | ExternalDNS | deleted (gate) | must be absent | — | — |
| Route 53 zone `civo.` | bootstrap | Terraform | — | — | — | destroyed |
| TLS Secret copy (SSM) | persistent | scripts | written | — | deleted | — |
| Roles Anywhere anchor/profile/roles | bootstrap | Terraform | — | — | — | destroyed |
| CA files | bootstrap (Git) | operator | — | — | — | rotate/delete manually |
| SSM parameters | per layer | Terraform | — | cluster ones destroyed | persistent ones destroyed | bootstrap ones destroyed |
| KMS key, OIDC, lab-role | account | Terraform | — | — | — | — (account-down only) |

Steps: `PROVIDER=civo make full-up` → verify (Argo, Envoy TLS, DNS, ESO,
CNPG, observability, autoscaler present) → write rows → `make down` →
verify Civo listings (no cluster, no LB, artifact present, network and IP
present) → verify Route 53 records gone → `make up` → verify rows and TLS
reuse → `make down` → leak check → cost from the Civo dashboard.

## 5. Files/components affected

`tests/manual/civo-150-lifecycle.md` (new); evidence in this spec.

## 6. Implementation steps

Run the runbook; record every check with command and result.

## 7. Dependencies and blockers

120, 110, 070, 130 done; 160 and 170 optional but expected in M1.

## 8. Acceptance criteria

- All verifications pass; zero leaks in `civo` listings and AWS Route 53; cost recorded and compared to the model in `research.md`.
- AWS project untouched during the run (record `make status` for aws before and after).

## 9. Validation

Real cloud, ~1 USD.

## 10. AWS regression protection

AWS `make status` before/after unchanged; no AWS resources created except SSM/Route 53 records in the civo zone.

## 11. Rollout and rollback/recovery

Validation only; `persistent-down` for civo cleans artifacts if needed.

## 12. Risks and unresolved questions

- Observability volumes with Delete reclaim must not leave orphans; verified by listing.

## 13. Definition of done

- [ ] Runbook committed with evidence; classification table complete; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT. Not run.
