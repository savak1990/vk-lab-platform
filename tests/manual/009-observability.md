# Manual test plan: spec 009 observability

Covers `gitops/templates/platform/aws/observability/{kube-prometheus-stack,loki,alloy,metrics-server,monitors,dashboards,alerts}.yaml`,
the `scripts/argo-up.sh` Argo CD metrics edit, and `docs/adr/0018-defer-tracing-and-loki-filesystem-storage.md`.

No CI/automated test framework exists yet in this repo (specs 018/022/023 not implemented), so this is a manual
checklist to run by hand against a real cluster. Tick each box in order; each step names what to run, what to
look for, and what a pass looks like. Steps 4–6 are deliberately hop-by-hop rather than "open Grafana and look" —
each hop is a separate, independently-checkable link in the chain, which is also how you'd debug a broken one.

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

**Known open risk to watch for here specifically**: `dashboards.yaml`'s ConfigMaps target the `observability`
namespace, which is only created as a side effect of `kube-prometheus-stack`'s Application syncing
(`CreateNamespace=true`) one wave earlier. CLAUDE.md itself warns that sync-wave numbers order *when an
Application object is created*, not when everything inside it (a namespace, a CRD) is actually ready. If this
step ever fails with `namespaces "observability" not found`, that's this exact race — the fix is a `PreSync` hook
on `dashboards.yaml` waiting on the namespace, per CLAUDE.md's documented pattern for this hazard, not a bigger
wave gap (which would just narrow the race, not close it).

## 2. Loki Service/endpoint sanity check

`alloy.yaml`'s `loki.write` endpoint is hardcoded to `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push`.

- [ ] `kubectl get svc loki -n observability -o jsonpath='{.spec.ports[?(@.name=="http-metrics")].port}'`
- [ ] Confirm it prints `3100`.

Pass: port matches; if it doesn't, `alloy.yaml`'s `loki.write.endpoint.url` needs correcting before step 6 below
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

## 4. Deep dive: CNPG → Prometheus → Grafana, hop by hop

Learning goal: see each link in the chain independently, so a break in any one is diagnosable rather than a
single "Grafana shows nothing, now what?" black box.

**4.1 — the source: is the exporter really there, with Prometheus out of the picture entirely?**

```
kubectl get pods -n cnpg-system -l cnpg.io/cluster=lab-postgres
kubectl port-forward -n cnpg-system pod/<pod-name> 9187:9187
curl -s localhost:9187/metrics | grep cnpg_collector_up
```
Pass: a line like `cnpg_collector_up{cluster="lab-postgres",...} 1`. This metric comes straight from CNPG's
built-in exporter, baked into the Postgres pod itself — no sidecar, no separate process. If this fails, the
problem is CNPG/Postgres, not observability.

**4.2 — is our `PodMonitor` the thing Prometheus is actually honoring?**

```
kubectl get podmonitor cnpg-postgres -n cnpg-system -o yaml
```
Confirm `spec.selector.matchLabels` (`cnpg.io/cluster: lab-postgres`) matches the pod's real labels
(`kubectl get pod <pod-name> -n cnpg-system --show-labels`), and `spec.podMetricsEndpoints[0].port` (`metrics`)
matches the port *name* on the pod spec (`kubectl get pod <pod-name> -n cnpg-system -o jsonpath='{.spec.containers[*].ports}'`).

**4.3 — did the Prometheus Operator pick it up and is the scrape succeeding?**

```
kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090
```
Open `http://localhost:9090/targets`, find the pool named `podMonitor/cnpg-system/cnpg-postgres/0`.
Pass: state `UP`, no scrape error. If it's missing entirely, the Operator hasn't reconciled the PodMonitor yet
(check `kubectl logs -n observability -l app=kube-prometheus-stack-operator`); if it's `DOWN`, the scrape itself
is failing (compare the error shown here against what step 4.1 returned directly).

**4.4 — is the metric actually in Prometheus's TSDB?**

In the same Prometheus UI, run the query `cnpg_collector_up{cluster="lab-postgres"}` under **Graph**.
Pass: returns a series with value `1`.

**4.5 — the visual layer**

Retrieve Grafana's admin password and port-forward (see step 5's Grafana sub-steps, same commands), open the
**CloudNativePG** dashboard, confirm the "Instance up" and "WAL ready to archive" panels show data.

If 4.1–4.4 all passed but 4.5 doesn't, the problem is Grafana-side (wrong datasource, dashboard JSON typo) —
you've already proven the data exists.

## 5. Deep dive: Karpenter → Prometheus → Grafana → Alert, hop by hop

Same shape as CNPG's walkthrough, but Karpenter's chart creates a real `Service` (unlike CNPG), so this uses a
`ServiceMonitor` instead of a `PodMonitor` — worth noticing the difference as you go through it.

**5.1 — the source, bypassing Prometheus**

```
kubectl port-forward -n kube-system svc/karpenter 8080:8080
curl -s localhost:8080/metrics | grep nodepool
```
Pass: `karpenter_nodepools_usage` and `karpenter_nodepools_limit` both appear, each carrying a `nodepool=` and
`resource_type=` label. (These names were confirmed against Karpenter's own source during implementation,
`pkg/metrics/constants.go` — this step is the live-cluster confirmation that was still outstanding.)

**5.2 — the `ServiceMonitor` and Prometheus's target list**

```
kubectl get servicemonitor karpenter -n kube-system -o yaml
```
Confirm `spec.selector.matchLabels` (`app.kubernetes.io/name: karpenter`) matches the Service's labels, and
`spec.endpoints[0].port` (`http-metrics`) matches a port *name* on that Service (`kubectl get svc karpenter -n kube-system -o yaml`).
Then, same Prometheus UI as step 4.3, find pool `serviceMonitor/kube-system/karpenter/0`, confirm `UP`.

**5.3 — the metric in Prometheus**

Query `karpenter_nodepools_usage{resource_type="cpu"} / karpenter_nodepools_limit{resource_type="cpu"}`.
Pass: one series per NodePool (`spot`, `on-demand`), values between 0 and 1.

**5.4 — the alert rule watching the same series**

```
kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093
```
Open `http://localhost:9093`, find `KarpenterNodePoolNearCapacityLimit` under **Alerts**. Pass: listed with state
`inactive` (not firing — expected at low utilization) rather than absent. Absent means the rule itself failed to
load; check `kubectl get prometheusrule observability-alerts -n observability -o yaml` and the Prometheus UI's
**Rules** page for a load error.

**5.5 — Grafana**

Retrieve the Grafana admin password and port-forward:
```
kubectl get secret -n observability kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
```
Log in at `http://localhost:3000` (user `admin`). Open **Karpenter Capacity**, confirm both panels ("NodePool CPU
usage vs limit", "Nodes per NodePool") show data, and confirm the chart's bundled Kubernetes cluster/node/pod
dashboards also show live data.

## 6. Deep dive: Alloy's log pipeline, hands-on

This is the answer to "how do I actually see what Alloy is doing" — Alloy ships a live UI, not just logs.

**6.1 — open the Alloy UI**

```
kubectl port-forward -n observability svc/alloy 12345:12345
```
Open `http://localhost:12345`. You'll see a graph of every component in `alloy.yaml`'s River config:
`discovery.kubernetes "pods"` → `discovery.relabel "pods"` → `loki.source.kubernetes "pods"` → `loki.write "default"`.
This graph *is* the pipeline — reading it left to right is reading the actual data flow.

**6.2 — confirm discovery actually found the tainted node's pod**

Click into `discovery.kubernetes "pods"`. Its debug/exports view lists every discovered target (one per pod on
this Alloy instance's own node — remember each Alloy pod only watches its own node via the `spec.nodeName`
field selector). Pick the Alloy pod running on the same node as CNPG's Postgres pod:
```
kubectl get pods -n cnpg-system -l cnpg.io/cluster=lab-postgres -o jsonpath='{.items[0].spec.nodeName}'
kubectl get pods -n observability -l app.kubernetes.io/name=alloy -o wide   # match the same NODE column
```
Port-forward to *that specific* Alloy pod's UI (`kubectl port-forward -n observability pod/<that-alloy-pod> 12345:12345`)
and confirm the Postgres pod appears in `discovery.kubernetes`'s target list. Pass: it's there. If it's missing,
the `controller.tolerations: [{operator: Exists}]` override isn't working and Alloy never scheduled onto that
node at all — check `kubectl get pods -n observability -l app.kubernetes.io/name=alloy -o wide` for one running
on that node in the first place.

**6.3 — check `loki.write`'s health and self-metrics**

Click into `loki.write "default"` in the UI — its health only ever reports unhealthy on a bad config (a
`loki.write` component doesn't expose extra debug info by design, per Alloy's own docs), so for delivery
problems (drops, retries) go to its self-metrics instead:
```
curl -s localhost:12345/metrics | grep loki_write
```
Pass: counters for sent bytes/entries climbing over repeated calls, drop/retry counters flat at (or near) zero.
Rising drop counters mean Loki is rejecting or unreachable — cross-check against step 2's endpoint sanity check.

**6.4 — the real end-to-end proof: trace one specific line through the whole pipeline**

```
kubectl exec -n cnpg-system <postgres-pod> -c postgres -- sh -c 'echo "OBSERVABILITY-PROBE-$(date +%s)"'
```
(Any pod's stdout works — Postgres's is used here since you already have its name from step 4.) Within roughly
10–30 seconds (Alloy tails files near-real-time; Loki's own ingestion is fast), query it back:

In Grafana Explore (Loki datasource): `{namespace="cnpg-system"} |= "OBSERVABILITY-PROBE"`

Pass: the exact line you echoed appears. This is a stronger check than a generic `{namespace="cnpg-system"}`
query — it proves a specific write reached Loki within a bounded time window, not just that *some* old logs are
sitting there from before Alloy was even involved.

**6.5 — Alloy's own pod logs, for anything the UI doesn't surface**

```
kubectl logs -n observability -l app.kubernetes.io/name=alloy --tail=50
```
Pass: no repeated scrape/relabel/push error lines in steady state. Occasional single retries during a Loki
restart are expected; a continuous stream of errors is not.

## 7. Trigger `PodCrashLooping` (the spec 009 acceptance-test alert)

- [ ] `kubectl run crashloop --image=busybox --restart=Always -- /bin/false`
- [ ] In the same Alertmanager UI from step 5.4, confirm `PodCrashLooping` transitions to `firing` within its
      `for: 1m` window.
- [ ] Clean up: `kubectl delete pod crashloop`.

Do **not** trigger this by editing an Argo-managed Deployment/StatefulSet — `syncPolicy.automated.selfHeal: true`
reverts drift on Argo-managed resources before the alert's `for:` window elapses, so the test would silently
fail to fire rather than error clearly. The throwaway imperative pod above is not Argo-managed, so it's safe.

Pass: alert shows `firing` in Alertmanager's UI before cleanup.

## 8. PVC usage vs retention

Prometheus: `retention: 7d`, `retentionSize: 8GB`, PVC size `10Gi`. Loki: `retention_period: 168h` (7 days), PVC
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
      (re-check step 4/5's dashboards and that `PodCrashLooping`/`PersistentVolumeNearlyFull`/
      `KarpenterNodePoolNearCapacityLimit` all appear under Alertmanager's rule list).
- [ ] Confirm Prometheus/Loki's historical data is gone (expected — `ebs-delete`, not a bug).

Pass: all Applications self-heal to `Synced`/`Healthy`; dashboards and alert rules reappear from Git; no manual
`kubectl apply` was needed.
