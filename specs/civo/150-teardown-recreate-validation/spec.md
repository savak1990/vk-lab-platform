---
id: "CIVO-150"
title: "Full lifecycle validation on Civo: create, write, destroy, verify, recreate, verify, destroy, no leaks"
status: "READY"
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
recorded evidence. A resource classification table exists for every Civo
and AWS resource the target uses. The table names the owner and the
destroy/retain policy for each resource.

## 2. Scope and non-goals

In scope:

- The runbook `tests/manual/civo-150-lifecycle.md`.
- Execution.
- Evidence.
- The classification table.
- Leak checks.
- The cost record.

Not in scope: code changes beyond small fixes found during the run. Those
fixes go to the owning spec.

## 3. Current state / evidence

Existing AWS runbooks live under `tests/manual/`. `argo-down.sh` has gates.
`cluster-down.sh` has the leak sweep pattern.

## 4. Design and contracts

Fill the classification table during execution:

| Resource | Lifecycle | Owner | On `argo-down` | On `cluster-down` | On `persistent-down` | On `bootstrap-down` |
|---|---|---|---|---|---|---|
| Civo LB | cluster | CCM via Envoy Service | deleted (gate) | must be absent | — | — |
| Civo volumes (CNPG, observability) | disposable | CSI | deleted with the cluster | absent | — | — |
| Postgres dumps in S3 | persistent artifact | backup job | written at teardown, pruned to 2 | untouched | bucket emptied and deleted | — |
| Civo cluster, firewall | cluster | Terraform | — | destroyed | — | — |
| Civo network, reserved IP | persistent | Terraform | — | untouched | destroyed | — |
| Route 53 records | cluster | ExternalDNS | deleted (gate) | must be absent | — | — |
| Route 53 zone `civo.` | bootstrap | Terraform | — | — | — | destroyed |
| TLS Secret copy (SSM) | persistent | scripts | written | — | deleted | — |
| Roles Anywhere anchor/profile/roles | bootstrap | Terraform | — | — | — | destroyed |
| CA files | bootstrap (Git) | operator | — | — | — | rotate/delete manually |
| SSM parameters | per layer | Terraform | — | cluster ones destroyed | persistent ones destroyed | bootstrap ones destroyed |
| KMS key, OIDC, lab-role | account | Terraform | — | — | — | — (account-down only) |

Steps:

1. Run `PROVIDER=civo make full-up`.
2. Verify that Argo, Envoy TLS, DNS, ESO, CNPG, observability, and the autoscaler are present.
3. Write rows.
4. Run `make down`.
5. Verify the Civo listings: no cluster, no LB, artifact present, network and IP present.
6. Verify that the Route 53 records are gone.
7. Run `make up`.
8. Verify the rows and the TLS reuse.
9. Run `make down`.
10. Run the leak check.
11. Record the cost from the Civo dashboard.

## 5. Files/components affected

`tests/manual/civo-150-lifecycle.md` (new); evidence in this spec.

## 6. Implementation steps

Run the runbook. Record every check with its command and result.

## 7. Dependencies and blockers

120, 110, 070, 130 done. 160 and 170 are optional but expected in M1.

## 8. Acceptance criteria

- All verifications pass. There are zero leaks in the `civo` listings and in AWS Route 53. The cost is recorded and compared to the model in `research.md`.
- The AWS project is untouched during the run. Record `make status` for aws before and after the run.

## 9. Validation

Real cloud, ~1 USD.

## 10. AWS regression protection

AWS `make status` before and after the run is unchanged. No AWS resources are created except SSM/Route 53 records in the civo zone.

## 11. Rollout and rollback/recovery

Validation only. `persistent-down` for civo cleans the artifacts if needed.

## 12. Risks and unresolved questions

- Observability volumes with Delete reclaim must not leave orphans. Verify this by listing.

## 13. Definition of done

- [ ] Runbook committed with evidence; classification table complete; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT. Not run.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
