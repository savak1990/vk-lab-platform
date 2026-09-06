---
id: "CIVO-175"
title: "Right-size requests and limits from measured usage; re-evaluate memory-optimized SKUs"
status: "DRAFT"
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

Requests and limits for every platform pod reflect measured usage so the
idle cluster fits one Large node where possible, and the cost model is
updated with real numbers and a decision on RAM-optimized SKUs. The user
expects CPU waste and memory pressure; data decides.

## 2. Scope and non-goals

In scope: Prometheus queries over 7 days, a requests/limits table, values
changes in shared charts (applies to AWS too, through the same values),
SKU comparison, `research.md` cost update. Not in scope: changing the
pool SKU in Terraform (a separate one-line change once decided).

## 3. Current state / evidence

Current requests: Argo CD from `argo-up.sh`, CNPG 250m/256Mi, others chart
defaults. Allocatable: Large ~5.9 GiB. Cost model in `research.md`.

## 4. Design and contracts

- Queries: p95 `container_memory_working_set_bytes` and `rate(container_cpu_usage_seconds_total)` per pod over 7 days.
- Rule: request = p95 + 20%; memory limit = 2× request or chart guidance; CPU limits omitted.
- SKU table: Large (4/8) vs RAM-opt Small (2/16) with measured memory need; decide by `nodes needed × price`.

## 5. Files/components affected

`gitops/values.yaml`, shared chart files, `scripts/argo-up.sh` (Argo CD requests), `research.md`.

## 6. Implementation steps

1. Collect metrics; fill the table.
2. Apply values; golden aws diff shows only the intended request changes; sync on both providers.
3. Observe node count for 48 h; update the cost model.

## 7. Dependencies and blockers

160 (metrics), 170 (autoscaler behavior).

## 8. Acceptance criteria

- Table committed; no pod OOMKilled over 48 h after the change; idle node count recorded.
- SKU decision recorded in `decisions.md`.

## 9. Validation

Real cloud observation on civo; AWS sync check.

## 10. AWS regression protection

Request changes apply to AWS intentionally; verify no scheduling failures on the AWS system node.

## 11. Rollout and rollback/recovery

Revert values.

## 12. Risks and unresolved questions

- Karpenter on AWS may consolidate differently after request changes; observe.

## 13. Definition of done

- [ ] Table, values, cost model; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
