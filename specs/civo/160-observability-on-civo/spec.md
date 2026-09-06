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

Grafana at `grafana.civo.<root-domain>` shows cluster, CNPG, Envoy, and
Argo dashboards with logs from Loki, on Civo volumes, with the same
charts and retention as AWS. The Large pool has the headroom (HLD §2).

## 2. Scope and non-goals

In scope: hoisting the observability Applications with values for storage
class, spot affinity, EKS-vs-k3s scrape targets, kubelet TLS, Karpenter
gating; metrics-server on civo. Not in scope: Tempo/OTel (deferred ADR 0018),
retention changes, Civo-specific dashboards.

## 3. Current state / evidence

- `kube-prometheus-stack.yaml`: `storageClassName: ebs-delete` ×3; spot anti-affinity ×3; `kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy enabled: false` (EKS managed control plane); Grafana `existingSecret grafana-admin-credentials` (ESO).
- `loki.yaml`: SingleBinary, filesystem, `ebs-delete`, spot affinity.
- `metrics-server.yaml`: `--kubelet-insecure-tls`; Civo installs its own metrics-server by default (removed in CIVO-030).
- `monitors.yaml`, `alerts.yaml`, `dashboards.yaml`: Karpenter entries.

## 4. Design and contracts

- Move observability files to `shared/observability/` with values: `storage.className`, `capacity.spotAvoidance` (affinity rendered only when true), `observability.controlPlaneScrapes` (aws false; civo: try true for `kubeProxy`, `kubeControllerManager`, `kubeScheduler`; k3s exposes these on the server node only when configured; record what actually works and set values accordingly; do not claim), `observability.kubeletInsecureTls` (aws true; civo test false first).
- Karpenter ServiceMonitor, alert, dashboard gated on `.Values.target == "aws"`.
- PVC sizes unchanged (10Gi/1Gi/1Gi/10Gi) on `civo-volume`; volumes have Delete reclaim and are removed with the cluster (verified in CIVO-150).
- Resource requests recorded for CIVO-175.

## 5. Files/components affected

`gitops/templates/platform/shared/observability/*.yaml` (moved + templated), `gitops/values.yaml`.

## 6. Implementation steps

1. Template; golden aws diff empty.
2. `PROVIDER=civo make up`; all pods Ready; Grafana login via ESO secret; dashboards load; Loki receives logs.
3. Record node RAM usage with one node; confirm the cluster stays at 1–2 nodes.

## 7. Dependencies and blockers

050 (layout), 100 (Grafana admin secret).

## 8. Acceptance criteria

- All observability pods Ready on civo; Grafana reachable via HTTPS (after 070) with CNPG and Argo dashboards populated.
- Control-plane scrape results documented.
- AWS golden diff empty.

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo (~0.2 USD incl. volumes for an hour).

## 10. AWS regression protection

Template defaults equal AWS files (golden).

## 11. Rollout and rollback/recovery

Revert; Argo prunes; volumes deleted with PVCs.

## 12. Risks and unresolved questions

- RAM: full stack plus baseline may exceed one Large node; autoscaler (170) adds a second; acceptable per HLD.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
