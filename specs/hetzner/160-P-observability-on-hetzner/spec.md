---
id: "HETZ-160"
title: "Observability stack on Hetzner: control-plane scrapes enabled, x86 images, hcloud-volumes with the 10 GB floor"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Values-level changes on the shared stack; the self-managed control plane inverts one Civo amendment and adds scrape targets"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-045", "HETZ-050", "HETZ-085", "CIVO-160"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-20"
completed: ""
---

# HETZ-160 — Observability on Hetzner

## 1. Outcome and rationale

Grafana at `grafana.hz.<root-domain>` shows the cluster, control
plane, CNPG, Envoy and Argo dashboards with logs from Loki. The stack runs
on `hcloud-volumes` with the same charts and retention as AWS and Civo.
Unlike the managed control plane on Civo, the control plane is a node in
this cluster, so its scheduler and controller-manager are scrapeable.
Two fixed `cx33` nodes (8 GB each) plus 0–2 autoscaled give about 14 GiB
fixed and up to about 28 GiB at the four-node ceiling, so no trimming is
needed.

Read `specs/civo/160-D-observability-on-civo/spec.md` first.

## 2. Scope and non-goals

In scope: the `observability.*` and `storage.*` values for
`target: hetzner`; control-plane scrape targets; the Argo-installed
metrics-server; sizing on `cx33`. Not in scope: Tempo/OTel
(ADR 0018), retention changes, Hetzner-specific dashboards beyond the
optional CCM/CSI metrics.

## 3. Current state / evidence

- CIVO-160 hoists `shared/observability/*` with values
  `storage.className`, `capacity.spotAvoidance`,
  `observability.controlPlaneScrapes`, `observability.kubeletInsecureTls`,
  and gates Karpenter assets on `aws`. Its review amendment keeps
  control-plane scrapes off on Civo because the managed control plane is
  hidden. That amendment does not apply here.
- HETZ-030's `control-plane.yaml.tftpl` passes
  `--kube-controller-manager-arg=bind-address=10.0.1.10`,
  `--kube-scheduler-arg=bind-address=10.0.1.10` and
  `--etcd-expose-metrics`, so scheduler, controller-manager and etcd
  metrics are scrapeable on the private IP. k3s runs these components as
  goroutines inside one process rather than as static pods, but each still
  serves its own metrics endpoint on its usual port, so the
  kube-prometheus-stack scrape configuration is the same shape as on any
  self-managed cluster.
  https://docs.k3s.io/cli/server ; https://docs.k3s.io/reference/server-config
- k3s ships metrics-server, so this target installs none of its own:
  `metricsServerEnabled` returns **false** on hetzner and no
  `--kubelet-insecure-tls` flag is needed, because k3s signs its kubelet
  serving certificates with the cluster CA. The render check still
  requires exactly one metrics-server Deployment in the cluster; here it is
  k3s's, in `kube-system`, and not an Argo CD Application.
- `--etcd-expose-metrics` binds embedded etcd's metrics to
  `http://0.0.0.0:2381/metrics`, reachable on the private address and
  blocked from the public one by the firewall (HETZ-030). It exists only
  because HETZ-030 chose `--cluster-init`; with the SQLite default there
  would be no etcd target at all.
- k3s runs kube-proxy by default and flannel does not replace it, so the
  `kubeProxy` scrape has a real target.
- HETZ-030 records allocatable memory on `cx33` (record the figure here;
  research.md estimates about 7 GiB per node).
- Every image in the stack publishes `linux/amd64` (research.md, x86 row).
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
  `kubeEtcd.enabled: true`, scraping `http://10.0.1.10:2381/metrics`
  (embedded etcd through `--etcd-expose-metrics`, no client cert needed on
  the http metrics URL); `kubeProxy.enabled: true` with `endpoints` = the
  private IPs of the fixed nodes (two in M1; autoscaled nodes are not
  scrape targets for control-plane metrics), because k3s runs kube-proxy
  and flannel does not replace it — record the result.
- `observability.kubeletInsecureTls`: try `false` first. k3s signs its
  kubelet serving certificates with the cluster CA, so Prometheus should
  trust them without the flag. Record the result; if the scrape fails, set
  `true` and record why, rather than assuming either way.
- node-exporter runs on the two fixed nodes (and any autoscaled node).
  The control-plane node carries no taint — k3s taints a server node only
  when asked, and HETZ-030 does not ask — so no toleration is needed; add
  `tolerations: [{operator: Exists}]` anyway for the day HETZ-170 taints
  anything.
- metrics-server: k3s ships one, so `metricsServerEnabled` returns
  **false** on hetzner and no Application is rendered. The render check
  still requires exactly one metrics-server Deployment in the cluster; on
  this target it is k3s's own, in `kube-system`, carrying no Argo CD
  ownership labels.
- Karpenter ServiceMonitor, alert and dashboard stay gated to `aws`.
- Optional: enable `HCLOUD_METRICS_ENABLED` on the CCM (`argo-up` helm
  values) and the CSI chart's `metrics.enabled`, with ServiceMonitors under
  `platform/hetzner/observability/`. P3 inside this spec; do not block on
  it.
- Sizing: Prometheus `resources.limits.memory` 2Gi, Loki 1Gi, Grafana
  512Mi. A single pod may use up to about 7 GiB on `cx33`, so no pod is
  near the ceiling. Record requests for SHARED-048.

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
   ESO secret. Dashboards populated. Loki receives logs from every node,
   fixed and autoscaled.
3. In Prometheus, confirm `up{job="kube-controller-manager"}` and
   `up{job="kube-scheduler"}` are 1. Record `kubeProxy` and
   `kubeletInsecureTls` outcomes.
4. `hcloud volume list`: four 10 GB volumes plus CNPG's.
5. Record per-node memory usage for SHARED-048.

## 7. Dependencies and blockers

HETZ-045 (the initialised cluster and the control-plane private IP the
scrape endpoints use), HETZ-050 (storage class,
render sets), HETZ-085 (Grafana admin secret through ESO), CIVO-160
(hoisted stack and values keys).

## 8. Acceptance criteria

- All observability pods Ready on hetzner; Grafana reachable through HTTPS
  (after HETZ-070); CNPG, Argo and control-plane dashboards populated.
- `kube-controller-manager` and `kube-scheduler` targets are `up`.
- `kubeEtcd` targets are `up`, proving `--etcd-expose-metrics` reaches
  embedded etcd on the private address, and `nc -zv <cp public ip> 2381`
  fails.
- Exactly one metrics-server Deployment exists: k3s's own, in
  `kube-system`, with no Argo CD ownership label and no
  `--kubelet-insecure-tls` flag. `kubectl top nodes` returns figures.
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

- The self-managed control plane exposes scheduler and
  controller-manager metrics with authentication; the ServiceMonitor
  uses the Prometheus ServiceAccount bearer token and needs the
  `system:monitoring`-style RBAC that kube-prometheus-stack ships. If
  that rejects it, fall back to
  `--kube-scheduler-arg=authentication-skip-lookup=true` on HETZ-030's
  control-plane install line and record the change there.
- k3s serves every control-plane component from one process. If a future
  k3s release changes a component's metrics port or stops binding one
  separately, the scrape breaks with no other symptom; the §8 criteria name
  each target so a version bump is checked against them.
- The 10 GB floor means every future small PVC costs 0.57 EUR/month;
  note it in `research.md`.

## 13. Definition of done

- [ ] Evidence; control-plane scrape results documented; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm: stacked etcd scraped, kube-proxy kept,
  metrics-server Argo-installed; depended on the Cilium CNI spec, since
  retired, instead of HETZ-030; x86 images.
- 2026-09-20 — option C: the control-plane metrics `extraArgs` are set by
  HETZ-030's `control-plane.yaml.tftpl`, not by the kubeadm bootstrap spec (decisions.md §3,
  "Control-plane metrics").
- 2026-09-20 — k3s (HETZ-017, ADR 0037). Scrape targets stay, their source
  changes: `--kube-controller-manager-arg`, `--kube-scheduler-arg` and
  `--etcd-expose-metrics` on HETZ-030's install line in place of kubeadm
  `extraArgs`. etcd is a target at all only because HETZ-030 chose
  `--cluster-init`; SQLite would have had none. metrics-server flips from an
  Argo CD Application to k3s's bundled one, so `metricsServerEnabled` returns
  false on hetzner and `kubeletInsecureTls` is tried as `false` first.
  `depends_on` moves from the retired Cilium CNI spec to HETZ-045. Dashboards, volumes, the
  10 GB floor, retention and sizing are unchanged.

- 2026-09-22 — HETZ-060 clears part of §8's first criterion early. "Grafana
  reachable through HTTPS (after HETZ-070)" no longer waits for HETZ-070:
  that spec was narrowed because the Gateway's HTTPS listener and the
  ExternalDNS records both had to land with the load balancer. Measured on
  the live cycle, `https://grafana.hz.<root>/` through the hcloud load
  balancer returned 302 to Grafana's own login page, which is the reachable
  answer for an unauthenticated request. The `grafana` HTTPRoute and the
  `grafana-traffic-policy` BackendTrafficPolicy both render and are Accepted,
  and both moved from the forbidden to the required set in
  `gitops-render-check.sh`.

  What stays open here is unchanged: the control-plane scrapes
  (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy` are
  disabled chart-wide with no per-target gate), the control-plane IP relay,
  and the dashboards those scrapes populate.

  Also observed, and useful for §4's sizing paragraph: on three `cx33` the
  observability claims bound as three 10Gi `hcloud-volumes` PVCs - Prometheus,
  Alertmanager and Loki - with Grafana taking none, so the volume count is
  three rather than the four §3 predicts. Alertmanager's 1Gi request was
  rounded up to Hetzner's 10Gi floor, which is the behaviour §4 expected.
- 2026-09-22 — observed on HETZ-085's cycle, three `cx33` in `fsn1`. The PVC
  count is three, not the four §3 predicts, and this is now the second cycle
  to show it: `prometheus`, `alertmanager` and `loki` each bind one 10Gi
  `hcloud-volumes` claim, and Grafana binds none. Alertmanager's 1Gi request
  is rounded up to Hetzner's 10Gi floor as expected, so the floor costs two
  extra volumes' worth of storage on every bring-up, not one. Nothing here
  touches the control-plane scrapes, which stay disabled chart-wide with no
  per-target gate.

- 2026-09-23 - HETZ-070's two cycles confirm the three-PVC count a third and
  fourth time: Prometheus, Alertmanager and Loki bind one 10Gi
  `hcloud-volumes` claim each, Grafana none.

- 2026-09-23 - the three-PVC count holds a fifth time on HETZ-115's cycle
  (Prometheus, Alertmanager, Loki at 10Gi each on `hcloud-volumes`; Grafana
  none). Also measured: the Grafana e2e spec passes on hetzner today, so this
  spec's remaining work is the control-plane scrapes, not Grafana itself.
