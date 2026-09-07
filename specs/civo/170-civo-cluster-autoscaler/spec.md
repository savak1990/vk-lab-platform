---
id: "CIVO-170"
title: "Civo cluster autoscaler on the Large pool, 1 to 3 nodes"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Marketplace app or upstream chart plus one Terraform lifecycle rule; the open item is the credential exposure, which needs research"
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

The Civo cluster autoscaler keeps the `workers` pool between 2 and 5
Medium nodes. It adds a node when pods stay pending. It removes a node
after sustained underutilization. This keeps the idle cost near one node.

This work is deferred to milestone M2 at priority P3. The reason is a
credential problem, not a technical one. See section 12. Milestone M1
runs a fixed node count instead.

## 2. Scope and non-goals

In scope:

- The install method.
- `--nodes=2:5:workers`.
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

- Install: prefer the Argo-managed upstream `cluster-autoscaler` Helm chart with the `civo` cloud provider, if the chart supports it for the pinned version. Otherwise, add the marketplace app to `applications` in CIVO-030's cluster resource. In that case, `argo-up` performs a documented `kubectl patch` of the Deployment args to `--nodes=2:5:workers`. The patch is idempotent. Record which path was taken. Argo-managed is preferred for GitOps ownership.
- Terraform: add `lifecycle { ignore_changes = [pools[0].node_count] }` on `civo_kubernetes_cluster`.
- Values: `capacity.autoscaler: {min: 2, max: 5, pool: workers}`.
- Credential: both the marketplace app and the upstream `civo` cloudprovider need a Civo API key as a Secret in `kube-system`. Use a **dedicated second API key** (Civo accounts may hold several). Store it as `secrets/civo-autoscaler-token.enc`. `argo-up` delivers it (never the main token). Then a Secret read in `kube-system` does not yield full account control. ADR 0030 must state this.
- Civo docs recommend a minimum of 2 workers with the autoscaler. The spike and this spec verify that `min=1` is honored.
- Observability: a ServiceMonitor for the autoscaler metrics (gated to civo).

**Review amendments (2026-09-06, kubernetes-architect):**
- Install path: the upstream `cluster-autoscaler` Helm chart supports `cloudProvider: civo` with `autoscalingGroups: [{name: workers, minSize: 1, maxSize: 3}]` and a Secret `civo-api-access` (`secretKeyRefNameOverride`). Use it as an Argo Application; `argo-up` creates the Secret from the dedicated key like the CA Secret. The marketplace app is the fallback.
- Scale-down blockers to remove on Civo: CNPG `spec.enablePDB: false` (CIVO-120); `--skip-nodes-with-system-pods=false` or move external-dns out of `kube-system` (it has no PDB); annotate pods with `emptyDir` scratch (`cluster-autoscaler.kubernetes.io/safe-to-evict-local-volumes`) or set `--skip-nodes-with-local-storage=false`.
- Acceptance adds: after the burst test, the cluster returns to two nodes within the scale-down window with the platform pods running.

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

**Open problem: the autoscaler needs an account-wide Civo API key inside the cluster.**

The Civo cloud provider for the cluster autoscaler reads `CIVO_API_KEY`
from a Secret in `kube-system`. Civo documents one API key per account
and a Regenerate button. Multiple keys appear only when an account
belongs to an Organization, and each key is tied to one account
(https://www.civo.com/docs/account/api-keys). A personal account
therefore has one key.

That key can delete every cluster, volume, load balancer, and object
store in the account. Any reader of that Secret, and any workload that
reaches it, holds full control of the Civo account. This is a larger
blast radius than every other credential in the platform.

Research needed before this spec becomes READY:

1. Does a Civo Organization or team account give a second account with its own key, and at what cost?
2. Does Civo offer scoped API keys that the public documentation does not describe? Ask Civo support.
3. Can the autoscaler run with a narrower credential, for example one limited to node-pool endpoints?
4. If none of the above holds, is the exposure acceptable for a single-operator lab with no untrusted workloads? Record the answer in ADR 0030.

Until that research completes, milestone M1 uses a fixed node count set
by Terraform. The cost stays deterministic and no Civo credential lives
in the cluster.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).

- 2026-09-06 — user decision: deferred to P3 and milestone M2. A personal Civo account has one API key, and the autoscaler would place that account-wide key in the cluster. Research items recorded in section 12.

