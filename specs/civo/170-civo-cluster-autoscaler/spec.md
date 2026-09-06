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
nodes. It scales up on pending pods. It scales down on sustained
underutilization. Terraform does not fight it. This keeps the idle cost
near one node (HLD §2).

## 2. Scope and non-goals

In scope:

- The install method.
- `--nodes=1:3:workers`.
- Terraform `ignore_changes`.
- A scale test.
- PodDisruptionBudget notes.

Not in scope: multiple pools, spot-like capacity (Civo has none), Karpenter
parity.

## 3. Current state / evidence

- The autoscaler is a marketplace app (`civo-cluster-autoscaler`). Its config is `--nodes=min:max:poolname`. It runs in `kube-system`. The default is `1:10:workers`. No Terraform coordination is documented (research.md).
- `civo_kubernetes_cluster.applications` installs marketplace apps at creation. Terraform does not support updates.
- Civo documents the scale-down order. The upstream cluster-autoscaler honors PDBs.

## 4. Design and contracts

- Install: prefer the Argo-managed upstream `cluster-autoscaler` Helm chart with the `civo` cloud provider, if the chart supports it for the pinned version. Otherwise, add the marketplace app to `applications` in CIVO-030's cluster resource. In that case, `argo-up` performs a documented `kubectl patch` of the Deployment args to `--nodes=1:3:workers`. The patch is idempotent. Record which path was taken. Argo-managed is preferred for GitOps ownership.
- Terraform: add `lifecycle { ignore_changes = [pools[0].node_count] }` on `civo_kubernetes_cluster`.
- Values: `capacity.autoscaler: {min: 1, max: 3, pool: workers}`.
- Credential: both the marketplace app and the upstream `civo` cloudprovider need a Civo API key as a Secret in `kube-system`. Use a **dedicated second API key** (Civo accounts may hold several). Store it as `secrets/civo-autoscaler-token.enc`. `argo-up` delivers it (never the main token). Then a Secret read in `kube-system` does not yield full account control. ADR 0028 must state this.
- Civo docs recommend a minimum of 2 workers with the autoscaler. The spike and this spec verify that `min=1` is honored.
- Observability: a ServiceMonitor for the autoscaler metrics (gated to civo).

## 5. Files/components affected

`terraform/modules/civo-k8s/main.tf`, `gitops/templates/platform/civo/autoscaler/*.yaml` or `argo-up` patch step, `gitops/values.yaml`.

## 6. Implementation steps

1. Choose the install path. Apply it.
2. Run the scale test. Deploy a burst Deployment that requests 3 GiB per replica × 4. Observe the nodes go 1→3 within 10 min. Delete the Deployment. Observe the scale-down to 1 within the autoscaler's window (~10–15 min).
3. `terraform plan` shows no `node_count` drift.

## 7. Dependencies and blockers

030 (cluster).

## 8. Acceptance criteria

- The scale up to 3 and the scale down to 1 are observed and timed.
- The plan is clean after scaling.
- Platform pods have PDBs or tolerate eviction. Record any pod that blocks scale-down.

## 9. Validation

Real cloud: the burst test (~0.2 USD).

## 10. AWS regression protection

Not applicable (Civo-only files).

## 11. Rollout and rollback/recovery

Remove the autoscaler. Set `node_count` explicitly.

## 12. Risks and unresolved questions

- The upstream chart's `civo` provider support and version. The fallback is documented.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
