---
id: "CIVO-160"
title: "Observability stack on Civo: kube-prometheus-stack, Loki, Alloy, metrics-server on civo storage with k3s scrape targets"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Values-level changes to existing charts; k3s differences are documented"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-050", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-160 — Observability on Civo

## 1. Outcome and rationale

Grafana at `grafana.civo.<root-domain>` shows the cluster, CNPG, Envoy, and
Argo dashboards with logs from Loki. The stack runs on Civo volumes with the
same charts and retention as AWS. The Large pool has the headroom (HLD §2).

## 2. Scope and non-goals

In scope: hoisting the observability Applications with values for these
items:

- storage class;
- spot affinity;
- EKS-vs-k3s scrape targets;
- kubelet TLS;
- Karpenter gating.

Also in scope: metrics-server on civo. Not in scope: Tempo/OTel (deferred,
ADR 0018), retention changes, Civo-specific dashboards.

## 3. Current state / evidence

- `kube-prometheus-stack.yaml` has `storageClassName: ebs-delete` ×3 and spot anti-affinity ×3. It sets `kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy enabled: false` (EKS managed control plane). Grafana uses `existingSecret grafana-admin-credentials` (ESO).
- `loki.yaml`: SingleBinary, filesystem, `ebs-delete`, spot affinity.
- `metrics-server.yaml` uses `--kubelet-insecure-tls`. Civo installs its own metrics-server by default (removed in CIVO-030).
- `monitors.yaml`, `alerts.yaml`, `dashboards.yaml` contain Karpenter entries.

## 4. Design and contracts

- Move the observability files to `shared/observability/` with these values:
  - `storage.className`.
  - `capacity.spotAvoidance`. The affinity is rendered only when this value is true.
  - `observability.controlPlaneScrapes`. On aws this value is false. On civo, try true for `kubeProxy`, `kubeControllerManager`, `kubeScheduler`. k3s exposes these on the server node only when configured. Record what actually works and set the values accordingly. Do not claim.
  - `observability.kubeletInsecureTls`. On aws this value is true. On civo, test false first.
- Gate the Karpenter ServiceMonitor, alert, and dashboard on `.Values.target == "aws"`.
- PVC sizes are unchanged (10Gi/1Gi/1Gi/10Gi) on `civo-volume`. The volumes have Delete reclaim. The volumes are removed with the cluster (verified in CIVO-150).
- Record the resource requests for CIVO-175.

## 5. Files/components affected

`gitops/templates/platform/shared/observability/*.yaml` (moved + templated), `gitops/values.yaml`.

## 6. Implementation steps

1. Template the files. The golden aws diff must be empty.
2. Run `PROVIDER=civo make up`. All pods must be Ready. Log in to Grafana with the ESO secret. The dashboards must load. Loki must receive logs.
3. Record the node RAM usage with one node. Confirm that the cluster stays at 1–2 nodes.

## 7. Dependencies and blockers

050 (layout), 100 (Grafana admin secret).

## 8. Acceptance criteria

- All observability pods are Ready on civo. Grafana is reachable through HTTPS (after 070). The CNPG and Argo dashboards are populated.
- The control-plane scrape results are documented.
- The AWS golden diff is empty.

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo (~0.2 USD incl. volumes for an hour).

## 10. AWS regression protection

The template defaults equal the AWS files (golden).

## 11. Rollout and rollback/recovery

Revert the change. Argo prunes the resources. The volumes are deleted with the PVCs.

## 12. Risks and unresolved questions

- RAM: the full stack plus the baseline may exceed one Large node. The autoscaler (170) adds a second node. This is acceptable per the HLD.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
