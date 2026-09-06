---
id: "CIVO-175"
title: "Right-size requests and limits from measured usage; re-evaluate memory-optimized SKUs"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Measurement-driven tuning across many charts; portable to AWS"
effort_estimate: "One session (4–6 h) after a week of metrics"
estimate_confidence: "low"
depends_on: ["CIVO-160", "CIVO-170"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-175 — Right-sizing and SKU re-evaluation

## 1. Outcome and rationale

Requests and limits for every platform pod reflect measured usage. Then the
idle cluster fits one Large node where possible. The cost model is updated
with real numbers and a decision on RAM-optimized SKUs. The user expects
CPU waste and memory pressure. Data decides.

## 2. Scope and non-goals

In scope:

- Prometheus queries over 7 days.
- A requests/limits table.
- Values changes in shared charts. These apply to AWS too, through the same values.
- An SKU comparison.
- The `research.md` cost update.

Not in scope: changing the pool SKU in Terraform. That is a separate
one-line change once decided.

## 3. Current state / evidence

Current requests: Argo CD from `argo-up.sh`; CNPG 250m/256Mi; others use
chart defaults. Allocatable: Large ~5.9 GiB. The cost model is in
`research.md`.

## 4. Design and contracts

- Queries: p95 `container_memory_working_set_bytes` and `rate(container_cpu_usage_seconds_total)` per pod over 7 days.
- Rule: request = p95 + 20%. Memory limit = 2× request or chart guidance. CPU limits are omitted.
- SKU table: Large (4/8) vs RAM-opt Small (2/16) with the measured memory need. Decide by `nodes needed × price`.

## 5. Files/components affected

`gitops/values.yaml`, shared chart files, `scripts/argo-up.sh` (Argo CD requests), `research.md`.

## 6. Implementation steps

1. Collect the metrics. Fill the table.
2. Apply the values. The golden aws diff shows only the intended request changes. Sync on both providers.
3. Observe the node count for 48 h. Update the cost model.

## 7. Dependencies and blockers

160 (metrics), 170 (autoscaler behavior).

## 8. Acceptance criteria

- The table is committed. No pod is OOMKilled over 48 h after the change. The idle node count is recorded.
- The SKU decision is recorded in `decisions.md`.

## 9. Validation

Real cloud observation on civo; AWS sync check.

## 10. AWS regression protection

The request changes apply to AWS intentionally. Verify that there are no scheduling failures on the AWS system node.

## 11. Rollout and rollback/recovery

Revert the values.

## 12. Risks and unresolved questions

- Karpenter on AWS may consolidate differently after the request changes. Observe it.

## 13. Definition of done

- [ ] Table, values, cost model; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
