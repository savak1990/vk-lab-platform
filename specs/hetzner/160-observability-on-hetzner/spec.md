---
id: "HETZ-160"
title: "Observability stack on Hetzner: control-plane scrapes enabled, ARM images, hcloud-volumes with the 10 GB floor"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Values-level changes on the shared stack; the self-managed control plane inverts one Civo amendment and adds scrape targets"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-050", "HETZ-085", "CIVO-160"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-160 — Observability on Hetzner

## 1. Outcome and rationale

Grafana at `grafana.hetzner.<root-domain>` shows the cluster, control
plane, CNPG, Envoy and Argo dashboards with logs from Loki. The stack runs
on `hcloud-volumes` with the same charts and retention as AWS and Civo.
Unlike managed k3s on Civo, the control plane is a node in this cluster,
so its scheduler and controller-manager are scrapeable. Three CAX21 nodes
give about 21 GiB, so no trimming is needed.

Read `specs/civo/160-observability-on-civo/spec.md` first.

## 2. Scope and non-goals

In scope: the `observability.*` and `storage.*` values for
`target: hetzner`; control-plane scrape targets; the k3s bundled
metrics-server decision; sizing on CAX21. Not in scope: Tempo/OTel
(ADR 0018), retention changes, Hetzner-specific dashboards beyond the
optional CCM/CSI metrics.

## 3. Current state / evidence

- CIVO-160 hoists `shared/observability/*` with values
  `storage.className`, `capacity.spotAvoidance`,
  `observability.controlPlaneScrapes`, `observability.kubeletInsecureTls`,
  and gates Karpenter assets on `aws`. Its review amendment keeps
  control-plane scrapes off on Civo because managed k3s hides the control
  plane. That amendment does not apply here.
- HETZ-030 starts k3s with `--kube-controller-manager-arg bind-address=<cp private ip>`
  and `--kube-scheduler-arg bind-address=<cp private ip>`, keeps the
  bundled metrics-server, disables `local-storage`, and uses SQLite, so
  there is no etcd.
- HETZ-020 measured allocatable memory on CAX21 (record the figure here;
  research.md estimates about 7 GiB per node).
- Every image in the stack publishes `linux/arm64` (research.md, ARM row).
- `hcloud-volumes` minimum size is 10 GB. The Grafana and Alertmanager
  claims of 1 Gi become 10 GB volumes each.
- Civo's injected `otel-collector` DaemonSet does not exist on Hetzner.

## 4. Design and contracts

- `storage.className: hcloud-volumes`. PVC requests: Prometheus 10Gi,
  Loki 10Gi, Grafana 1Gi, Alertmanager 1Gi, unchanged. Real volumes:
  4 × 10 GB, 2.29 EUR/month (research.md cost model). Raising the 1Gi
  claims to 10Gi is optional and free; do it so the request matches the
  volume.
- `capacity.spotAvoidance: false`.
- `observability.controlPlaneScrapes: true` with per-component values:
  `kubeControllerManager.enabled: true`, `kubeScheduler.enabled: true`,
  both with `endpoints: [<cp private ip>]` from `argo-up` (SSM
  `/<project>/cluster-hetzner/k8s/control_plane_private_ip`) and
  `serviceMonitor.https: true`, `insecureSkipVerify: true`;
  `kubeEtcd.enabled: false` (SQLite); `kubeProxy` per the k3s default
  (k3s runs kube-proxy with flannel; try `enabled: true` with
  `endpoints` = the three private IPs, record the result).
- `observability.kubeletInsecureTls`: test `false` first; k3s kubelet
  serving certs are signed by the k3s server CA which Prometheus does not
  trust, so `true` is the expected outcome. Record it.
- node-exporter runs on all three nodes. The control-plane node carries
  no taint (HETZ-030), so no toleration is needed; add
  `tolerations: [{operator: Exists}]` anyway for the day HETZ-170 taints
  anything.
- metrics-server: the k3s bundled one stays (decisions.md §3). The shared
  `metrics-server.yaml` Application must not render on hetzner; gate it
  with `observability.metricsServer.enabled`, `false` on hetzner, `true`
  elsewhere. The render check forbids a second `metrics-server`
  Deployment on hetzner.
- Karpenter ServiceMonitor, alert and dashboard stay gated to `aws`.
- Optional: enable `HCLOUD_METRICS_ENABLED` on the CCM (`argo-up` helm
  values) and the CSI chart's `metrics.enabled`, with ServiceMonitors under
  `platform/hetzner/observability/`. P3 inside this spec; do not block on
  it.
- Sizing: Prometheus `resources.limits.memory` 2Gi, Loki 1Gi, Grafana
  512Mi. A single pod may use up to about 7 GiB on CAX21, so no pod is
  near the ceiling. Record requests for HETZ-175.

## 5. Files/components affected

`gitops/values.yaml` (hetzner block), `shared/observability/metrics-server.yaml`
(gate), `shared/observability/kube-prometheus-stack.yaml` (endpoints
values), `scripts/argo-up.sh` (control-plane private IP relay),
`scripts/gitops-render-check.sh` (hetzner sets),
`gitops/templates/platform/hetzner/observability/*` (optional).

## 6. Implementation steps

1. Add the values and the metrics-server gate. aws and civo golden diffs
   must be empty.
2. Run `PROVIDER=hetzner make up`. All pods Ready. Grafana login with the
   ESO secret. Dashboards populated. Loki receives logs from all three
   nodes.
3. In Prometheus, confirm `up{job="kube-controller-manager"}` and
   `up{job="kube-scheduler"}` are 1. Record `kubeProxy` and
   `kubeletInsecureTls` outcomes.
4. `hcloud volume list`: four 10 GB volumes plus CNPG's.
5. Record per-node memory usage for HETZ-175.

## 7. Dependencies and blockers

HETZ-030 (bind flags, metrics-server decision), HETZ-050 (storage class,
render sets), HETZ-085 (Grafana admin secret through ESO), CIVO-160
(hoisted stack and values keys).

## 8. Acceptance criteria

- All observability pods Ready on hetzner; Grafana reachable through HTTPS
  (after HETZ-070); CNPG, Argo and control-plane dashboards populated.
- `kube-controller-manager` and `kube-scheduler` targets are `up`.
- Exactly one metrics-server Deployment exists (`kube-system`, k3s).
- aws and civo golden diffs are empty.

## 9. Validation

Offline: golden diffs, kubeconform. Real cloud: hetzner, about 0.10 EUR
for an hour including volumes.

## 10. AWS regression protection

Template defaults equal the AWS files (golden). Civo: golden diff empty;
`observability.metricsServer.enabled` defaults `true`, so civo keeps
rendering the chart's metrics-server as CIVO-160 decided.

## 11. Rollout and rollback/recovery

Revert the values. Argo prunes. Volumes are deleted with the PVCs.

## 12. Risks and unresolved questions

- k3s exposes scheduler and controller-manager metrics with
  authentication; the ServiceMonitor uses the Prometheus ServiceAccount
  bearer token and needs the `system:monitoring`-style RBAC that
  kube-prometheus-stack ships. If k3s rejects it, fall back to
  `--kube-scheduler-arg authentication-skip-lookup=true` in HETZ-030 and
  record the change there.
- The 10 GB floor means every future small PVC costs 0.57 EUR/month;
  note it in `research.md`.

## 13. Definition of done

- [ ] Evidence; control-plane scrape results documented; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
