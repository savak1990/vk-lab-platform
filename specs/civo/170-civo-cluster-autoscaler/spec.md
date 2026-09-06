---
id: "CIVO-170"
title: "Civo cluster autoscaler on the Large pool, 1 to 3 nodes"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Marketplace app plus one Terraform lifecycle rule; verification is a scale test"
effort_estimate: "Half a session (2–3 h) plus scaling waits"
estimate_confidence: "medium"
depends_on: ["CIVO-030"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-170 — Cluster autoscaler

## 1. Outcome and rationale

The Civo cluster autoscaler keeps the `workers` pool between 1 and 3 Large
nodes, scaling up on pending pods and down on sustained underutilization,
without Terraform fighting it. This keeps idle cost near one node (HLD §2).

## 2. Scope and non-goals

In scope: install method, `--nodes=1:3:workers`, Terraform
`ignore_changes`, a scale test, PodDisruptionBudget notes. Not in scope:
multiple pools, spot-like capacity (Civo has none), Karpenter parity.

## 3. Current state / evidence

- Autoscaler is a marketplace app (`civo-cluster-autoscaler`), config `--nodes=min:max:poolname`, runs in `kube-system`, default `1:10:workers`; no Terraform coordination documented (research.md).
- `civo_kubernetes_cluster.applications` installs marketplace apps at creation; updates unsupported through Terraform.
- Scale-down order documented by Civo; PDBs are honored by upstream cluster-autoscaler.

## 4. Design and contracts

- Install: prefer Argo-managed upstream `cluster-autoscaler` Helm chart with the `civo` cloud provider if the chart supports it for the pinned version; otherwise the marketplace app added to `applications` in CIVO-030's cluster resource with a documented `kubectl patch` of the Deployment args to `--nodes=1:3:workers` performed by `argo-up` (idempotent). Record which path was taken; Argo-managed is preferred for GitOps ownership.
- Terraform: `lifecycle { ignore_changes = [pools[0].node_count] }` on `civo_kubernetes_cluster`.
- Values: `capacity.autoscaler: {min: 1, max: 3, pool: workers}`.
- Observability: ServiceMonitor for the autoscaler metrics (gated to civo).

## 5. Files/components affected

`terraform/modules/civo-k8s/main.tf`, `gitops/templates/platform/civo/autoscaler/*.yaml` or `argo-up` patch step, `gitops/values.yaml`.

## 6. Implementation steps

1. Choose install path; apply.
2. Scale test: deploy a burst Deployment requesting 3 GiB per replica × 4; observe nodes 1→3 within 10 min; delete; observe scale-down to 1 within the autoscaler's window (~10–15 min).
3. `terraform plan` shows no `node_count` drift.

## 7. Dependencies and blockers

030 (cluster).

## 8. Acceptance criteria

- Scale up to 3 and down to 1 observed and timed.
- Plan clean after scaling.
- Platform pods have PDBs or tolerate eviction (record any that block scale-down).

## 9. Validation

Real cloud: burst test (~0.2 USD).

## 10. AWS regression protection

Not applicable (Civo-only files).

## 11. Rollout and rollback/recovery

Remove the autoscaler; set `node_count` explicitly.

## 12. Risks and unresolved questions

- Upstream chart `civo` provider support and version; fallback documented.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
