# Manual test plan: spec 009 observability

Covers `gitops/templates/platform/aws/observability/{kube-prometheus-stack,loki,alloy,metrics-server,monitors,dashboards,alerts}.yaml`,
the `scripts/argo-up.sh` Argo CD metrics edit, and `docs/adr/0018-defer-tracing-and-loki-filesystem-storage.md`.

No CI/automated test framework exists yet in this repo (specs 018/022/023 not implemented), so this is a manual
checklist to run by hand against a real cluster. Tick each box in order; each step names what to run, what to
look for, and what a pass looks like.

## 0. Pre-flight (already done during implementation)

- [ ] Not required to repeat unless a file below changed since implementation. Already verified: `helm template`
      of the full `gitops` umbrella chart, plus each of `kube-prometheus-stack` (88.5.4), `loki` (7.3.0), `alloy`
      (1.12.0), `metrics-server` (3.14.0) standalone with their exact inlined values — all rendered with zero
      errors. If you've edited any observability YAML since, re-run:
      ```
      helm template gitops --set target=aws --set project=vk-lab-platform >/dev/null
      ```
      Pass: exits 0, no error output.

## 1. `make up` from clean — sync-wave order

- [ ] Run `make up` (or `scripts/argo-up.sh` directly) from a torn-down state.
- [ ] Watch `kubectl get applications -n argocd -w` (or read `argo-up.sh`'s own progress output).
- [ ] Confirm wave-1 apps (`kube-prometheus-stack`, `metrics-server`, `loki`) reach `Synced`/`Healthy` before
      wave-2 (`alloy`, the `monitors.yaml` ServiceMonitor/PodMonitor objects, the `dashboards.yaml` ConfigMaps)
      before wave-3 (`alerts.yaml`'s PrometheusRule).
- [ ] Confirm no Application ever reports a CRD-not-found error (the specific failure the wave split exists to
      prevent — `monitoring.coreos.com` CRDs come from `kube-prometheus-stack`, wave 1).

Pass: `kubectl get application root -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}'` prints
`Synced/Healthy`; no app shows an error referencing `no matches for kind "ServiceMonitor"` or similar.

## 2. Loki Service/endpoint sanity check

`alloy.yaml`'s `loki.write` endpoint is hardcoded to `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push`.

- [ ] `kubectl get svc loki -n observability -o jsonpath='{.spec.ports[?(@.name=="http-metrics")].port}'`
- [ ] Confirm it prints `3100`.

Pass: port matches; if it doesn't, `alloy.yaml`'s `loki.write.endpoint.url` needs correcting before step 5 below
will show any logs.

## 3. No-resources-set sanity check (deliberate choice — do not "fix" preemptively)

No observability component sets `resources.requests`/`resources.limits` — a deliberate choice to accept
noisy-neighbor behavior on the tight 4GiB system node rather than pre-guessing sizes (see the plan's Key
Decision 5). Without requests there's no risk of a `Pending` pod from over-reserving the node; without limits
there's no risk of an artificial OOMKill. If the node does run low on memory, the kubelet's node-pressure
eviction picks BestEffort pods first — i.e. these observability pods, not Argo CD/Karpenter/CNPG.

- [ ] After a short soak (an hour or so of normal use): `kubectl top pods -n observability`
- [ ] `kubectl describe node -l node-type=system` — check the `Events` section for `Evicted` or `OOMKilled`.

Pass: no evictions/OOMKills observed. Only if you *do* see one, add explicit `resources` to the specific
component that got evicted — do not add requests/limits speculatively across the board.

## 4. Grafana dashboards

- [ ] Retrieve the auto-generated admin password:
      ```
      kubectl get secret -n observability kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
      ```
- [ ] Port-forward: `kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80`
- [ ] Log in at `http://localhost:3000` (user `admin`, password from above).
- [ ] Confirm the chart's bundled default dashboards (Kubernetes cluster/node/pod/namespace overview) show live
      data.
- [ ] Confirm the two vendored dashboards render and show data: **Karpenter Capacity** (NodePool CPU
      usage-vs-limit, nodes per NodePool) and **CloudNativePG** (instance up, WAL ready-to-archive).

Pass: all three dashboard groups (bundled + 2 vendored) show non-empty panels, not "No data".

## 5. Loki log query (validates Alloy → Loki end-to-end, and the taint toleration)

- [ ] In Grafana, open **Explore**, select the **Loki** datasource.
- [ ] Query `{namespace="cnpg-system"}` — confirm log lines appear.
- [ ] Query `{namespace="argocd"}` — confirm log lines appear.

The `cnpg-system` query specifically confirms Alloy's DaemonSet actually reached the `on-demand` NodePool's
`dedicated=stateful:NoSchedule`-tainted node (where CNPG's Postgres pod runs) via its
`controller.tolerations: [{operator: Exists}]` override — without that toleration, Postgres logs would be
silently missing while everything else looked fine.

Pass: both queries return non-empty results.

## 6. Trigger `PodCrashLooping` (the spec 009 acceptance-test alert)

- [ ] `kubectl run crashloop --image=busybox --restart=Always -- /bin/false`
- [ ] Port-forward Alertmanager: `kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093`
- [ ] Open `http://localhost:9093`, confirm `PodCrashLooping` transitions to `firing` within its `for: 1m` window.
- [ ] Clean up: `kubectl delete pod crashloop`.

Do **not** trigger this by editing an Argo-managed Deployment/StatefulSet — `syncPolicy.automated.selfHeal: true`
reverts drift on Argo-managed resources before the alert's `for:` window elapses, so the test would silently
fail to fire rather than error clearly. The throwaway imperative pod above is not Argo-managed, so it's safe.

Pass: alert shows `firing` in Alertmanager's UI before cleanup.

## 7. Verify `KarpenterNodePoolNearCapacityLimit`'s metric name against the live endpoint

The alert's metric names (`karpenter_nodepools_usage`/`karpenter_nodepools_limit`, labels `nodepool` +
`resource_type`) were confirmed against Karpenter's own source (`pkg/metrics/constants.go`,
`pkg/controllers/metrics/nodepool/suite_test.go`), not against a live running instance.

- [ ] `kubectl port-forward -n kube-system svc/karpenter 8080:8080`
- [ ] `curl -s localhost:8080/metrics | grep nodepool`
- [ ] Confirm `karpenter_nodepools_usage` and `karpenter_nodepools_limit` both appear, each with a `nodepool=` and
      `resource_type=` label.

Pass: both metrics present with those exact label keys. If they differ, correct `alerts.yaml`'s
`KarpenterNodePoolNearCapacityLimit` expression and `dashboards.yaml`'s Karpenter Capacity panel accordingly.

## 8. PVC usage vs retention

Prometheus: `retention: 7d`, `retentionSize: 8GB` PVC size `10Gi`. Loki: `retention_period: 168h` (7 days), PVC
size `10Gi`.

- [ ] After a day or more of normal lab use: `kubectl exec -n observability <prometheus-pod> -- df -h /prometheus`
      (or equivalent `du`/`df` against the mounted data path for both Prometheus and Loki pods).
- [ ] Confirm usage stays comfortably under 10Gi for both.

Pass: usage well under the PVC size. If not, tighten `retention`/`retentionSize`/`retention_period` rather than
growing the PVC, per the constitution's cost-consciousness rule.

## 9. `make down` / `make up` — GitOps reconciliation survives teardown

Per ADR 0018, observability *data* is disposable (`ebs-delete`) and is not expected to survive teardown — only
the *configuration* must come back automatically via GitOps.

- [ ] `make down`
- [ ] `make up`
- [ ] Confirm all observability Applications (`kube-prometheus-stack`, `loki`, `alloy`, `metrics-server`) reach
      `Synced`/`Healthy` again with no manual intervention.
- [ ] Confirm the `dashboards.yaml` ConfigMaps and `alerts.yaml`'s `PrometheusRule` are present again post-recreation
      (re-check step 4's dashboards and that `PodCrashLooping`/`PersistentVolumeNearlyFull`/
      `KarpenterNodePoolNearCapacityLimit` all appear under Alertmanager's rule list).
- [ ] Confirm Prometheus/Loki's historical data is gone (expected — `ebs-delete`, not a bug).

Pass: all Applications self-heal to `Synced`/`Healthy`; dashboards and alert rules reappear from Git; no manual
`kubectl apply` was needed.
