---
id: "CIVO-160"
title: "Observability stack on Civo: kube-prometheus-stack, Loki, Alloy, metrics-server on civo storage with k3s scrape targets"
status: "DONE"
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
updated: "2026-09-17"
completed: "2026-09-17"
---

# CIVO-160 — Observability on Civo

## 1. Outcome and rationale

Grafana at `grafana.civo.<root-domain>` shows the cluster and CNPG dashboards,
with Argo and Envoy metrics queryable in Grafana Explore (dedicated
dashboards for those two are deferred to a later spec, 2026-09-16 user
decision) and logs from Loki. The stack runs on Civo volumes with the same
charts and retention as AWS, on the fixed 3 × Medium pool (not a Large pool)
— headroom is tight, not comfortable; see §12.

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
- `metrics-server.yaml` uses `--kubelet-insecure-tls`. Measured 2026-09-17: Civo ships no metrics-server on this cluster (no `v1beta1.metrics.k8s.io` APIService, no pod) — CIVO-030 did not remove one. The stack deploys its own, gated by `observability.metricsServer.enabled`.
- `monitors.yaml`, `alerts.yaml`, `dashboards.yaml` contain Karpenter entries.

## 4. Design and contracts

- Move the observability files to `shared/observability/` with these values:
  - `storage.className`.
  - `capacity.spotAvoidance`. The affinity is rendered only when this value is true.
  - Control-plane scrapes (`kubeControllerManager`/`kubeScheduler`/`kubeEtcd`/`kubeProxy`) stay disabled on both targets as plain `enabled: false` literals in `kube-prometheus-stack.yaml` — there is no `observability.controlPlaneScrapes` values key. The review amendment below already ruled out enabling these on k3s; the 2026-09-17 run confirms it (Prometheus target table in §14).
  - `observability.kubeletInsecureTls`. On aws this value is true (EKS's kubelet serving certs are self-signed per node). On civo, `platform.kubeletInsecureTls` renders `false` — verified 2026-09-17: `kubectl top nodes`/`kubectl top pods` succeed, 0 `x509` lines in metrics-server logs, and the rendered args carry no `--kubelet-insecure-tls`.
- Gate the Karpenter ServiceMonitor, alert, and dashboard on `.Values.target == "aws"`.
- PVC sizes are unchanged (10Gi/1Gi/1Gi/10Gi) on `civo-volume`. The volumes have Delete reclaim. Volume-leak defense is layered, not a single verified fact: Loki's StatefulSet now sets `enableStatefulSetAutoDeletePVC`/`whenDeleted: Delete` on both targets; `argo-down.sh` waits for `cnpg-system` and `observability` PVCs (and their bound PVs) to clear before Terraform runs; `cluster-down.sh`'s tagged dangling-volume sweep is the safety net. An earlier claim that a lifecycle-validation run had verified this was wrong. Verified instead on 2026-09-17: after `PROVIDER=civo make down`, the Civo API reported 0 volumes and 0 clusters in LON1, but the "waiting for PVC/PV" log lines did not print because the Argo cascade had already deleted them before the wait loop ran — the outcome is proven, the wait code paths were not exercised on this run.
- Record the resource requests for CIVO-175 (figures in §14).
- This stack ships no OpenTelemetry Collector of its own (Tempo/OTel stay out of scope, ADR 0018). Civo's own `otel-collector` DaemonSet in `kube-system` is left untouched and runs beside the stack — verified 2026-09-17 it sets no `hostPort`/`hostNetwork` and requests `0`/`0`, so there is no port or resource conflict to resolve.
- Size this stack against 2308 MiB of allocatable memory per Medium node. CIVO-020 measured that
  figure; re-measured 2026-09-17 (`2364012Ki`/2308 MiB per node, unchanged). Do not use the 2672 MiB that the Civo documentation states.

**Review amendments (2026-09-06, kubernetes-architect):**
- Keep `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, and `kubeProxy` scrapes disabled on Civo. Managed k3s binds these to localhost on control-plane hosts outside the pool and ships no Services for them. Kubelet, cAdvisor, and node-exporter are the realistic targets. Do not spend time on the alternative.

## 5. Files/components affected

`gitops/templates/platform/shared/observability/*.yaml` (moved + templated), `gitops/values.yaml`, `gitops/templates/_helpers.tpl` (new `platform.kubeletInsecureTls`/`platform.metricsServerEnabled` helpers), `scripts/argo-down.sh` (civo PVC/PV wait extended to `observability`).

## 6. Implementation steps

1. Template the files. The golden aws diff must match the baseline — the reviewed Loki retention-key change is the one accepted difference.
2. Run `PROVIDER=civo make up`. All pods must be Ready. Log in to Grafana with the ESO secret. The dashboards must load. Loki must receive logs.
3. Record the per-node RAM usage across all three nodes. The pool is a fixed 3 × Medium (`g4s.kube.medium`) node group with no autoscaler in M1 (CIVO-170 is READY, not applied) — record allocation and working-set percentage per node instead of expecting the count to change.

## 7. Dependencies and blockers

050 (layout), 100 (Grafana admin secret).

## 8. Acceptance criteria

- All observability pods are Ready on civo. Grafana is reachable through HTTPS (after 070) with basic auth from the ESO admin secret. Loki receives and serves logs through Grafana.
- The CNPG dashboard is populated. Argo and Envoy metrics are queryable in Grafana Explore — dedicated dashboards for them are deferred to a later spec (2026-09-16 user decision).
- The control-plane scrape results are documented.
- The AWS golden diff matches the baseline; the only accepted difference is the Loki `enableStatefulSetAutoDeletePVC`/`whenDeleted` retention keys (reviewed and accepted, not a regression).

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo (~0.2 USD incl. volumes for an hour).

## 10. AWS regression protection

The template defaults equal the AWS files (golden).

## 11. Rollout and rollback/recovery

Revert the change. Argo prunes the resources. The volumes are deleted with the PVCs.

## 12. Risks and unresolved questions

- RAM is tight, not comfortable. Measured 2026-09-17 after a full Argo sync on the 3 × Medium (2308 MiB allocatable/node) pool: allocated requests/limits (memory) per node were `1296Mi(56%)/2Gi`, `1568Mi(67%)/2464Mi(106%)`, `1046Mi(45%)/2090Mi`; CPU requests `430m`/`220m`/`260m`. `kubectl top nodes` working-set memory was `2459Mi(106%)`, `2606Mi(112%)`, `1471Mi(63%)` of allocatable — two of three nodes ran over their own allocatable figure. Top consumers by memory: grafana 589Mi, prometheus 307Mi, loki 161Mi, alloy 57–75Mi ×3.
- Bring-up produced OOM kills from undersized container limits, not node memory pressure: `argocd-application-controller-0` (limit 768Mi) was `OOMKilled` twice; `cert-manager-cainjector` (limit 64Mi) was `OOMKilled` once; `cert-manager` restarted 5+2 times with `Error`. All recovered to `Healthy`. No autoscaler exists yet — CIVO-170 is READY but not applied — to add a node if pressure grows. These figures and the OOM kills are handed to SHARED-048 for right-sizing; this spec changes no request or limit.

## 13. Definition of done

- [x] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).

- 2026-09-16 — user decision: §8 amended for dashboards. The CNPG dashboard must be populated; Argo and Envoy metrics must be queryable in Grafana Explore instead. Dedicated Argo/Envoy dashboards go to a later spec. Leaked volumes get fixed in this spec, using the AWS mechanism: Loki's StatefulSet gains `whenDeleted: Delete`, and the civo-only PVC wait in `argo-down.sh` (already covering `cnpg-system`) is extended to `observability`.

- 2026-09-16 — **offline implementation complete** (commits `9bf385a`..`cabecec` — `de2c657`, `66dc999`, `9eaecbf`, `7303ad8`, `628c3c9`, `cabecec` — on `civo-160-observability`, two review rounds, no open Important/Critical findings). `kube-prometheus-stack.yaml`, `loki.yaml`, `alloy.yaml`, `metrics-server.yaml`, `monitors.yaml`, `alerts.yaml`, `dashboards.yaml` and `grafana-traffic-policy.yaml` moved to `gitops/templates/platform/shared/observability/`, templated against `storage.className`, `capacity.spotAvoidance`, and new helpers `platform.kubeletInsecureTls` (civo literal `false`) and `platform.metricsServerEnabled` (civo literal `true`). The Karpenter ServiceMonitor, alert, and dashboard are gated on `.Values.target == "aws"`. Loki sets `enableStatefulSetAutoDeletePVC: true`/`whenDeleted: Delete` on both targets. `argo-down.sh`'s civo PVC wait now covers `cnpg-system` and `observability`, and also waits for the matching PVs. `make gitops-check` GREEN: the aws render matches the golden baseline except the reviewed Loki retention-key diff (accepted, comment-only elsewhere); the civo render carries the expected M1 object set with no `ebs-delete`/Karpenter leakage; kubeconform reports 0 invalid on both renders; `bash -n` passes on every touched script. Parked minors are recorded in the plan's SDD ledger.

- 2026-09-17 — **Task 4 pre-flight, live Civo cluster (`vk-civo-lab`, found fully down beforehand).** `bootstrap-up` 2m, `persistent-up` 2m, `cluster-up` 6m, all exit 0. 3 nodes, k3s v1.35.0+k3s1, allocatable `2364012Ki`/`1880m` each (2308 MiB, matches CIVO-020, re-measured). No `v1beta1.metrics.k8s.io` APIService and no metrics-server pod on the stock cluster — kept `observability.metricsServer.enabled=true` on civo. Civo's own `otel-collector` DaemonSet in `kube-system` sets no `hostPort`/`hostNetwork` and requests `0`/`0` — left untouched, runs beside this stack.

- 2026-09-17 — **`argo-up` and verification, live civo cluster.** Exit 0, `"platform ready"`; all 11 child Applications `Synced`/`Healthy`; every observability pod `Running`; `metrics-server` `1/1`.

  **Kubelet TLS.** `platform.kubeletInsecureTls=false` works on civo: `kubectl top nodes`/`kubectl top pods` succeeded, 0 `x509` lines in metrics-server logs, and the rendered container args carry no `--kubelet-insecure-tls`. EKS keeps the flag (self-signed kubelet cert per node, unchanged).

  **Grafana.** `https://grafana.civo.<root-domain>/api/health` → 200; `/api/dashboards/home` (basic auth, ESO `grafana-admin-credentials` secret) → 200; certificate issued by Let's Encrypt (`YE1`).

  **Dashboards and queries.** CloudNativePG dashboard present and populated; `cnpg_collector_up{lab-postgres}` = 1. `up{...}` = 1 for the `argocd` targets and for `envoy-proxy`/`envoy-gateway`, both queryable in Grafana Explore. No Argo/Envoy dashboard exists — deferred to a later spec, per the 2026-09-16 amendment.

  **Logs.** Loki via Grafana Explore, query `{namespace="cnpg-system"}`: success, 2 streams, 5 lines (limit 5).

  **Control-plane scrape targets — Prometheus `/api/v1/targets`, all `up`:** `apiserver` 1, `kubelet` 9 (kubelet/cadvisor/probes × 3 nodes), `node-exporter` 3, `coredns` 1, `kube-state-metrics` 1, `prometheus` 2, `alertmanager` 2, `prometheus-operator` 1, `grafana` 1, `argocd` 5, `envoy` 2, `cnpg` 1. No `kube-controller-manager`/`scheduler`/`etcd`/`proxy` targets exist — disabled as plain literals on both targets, as designed; k3s binds these to localhost off-pool and EKS hides them.

  **Storage.** All five PVCs `Bound` on `civo-volume`: prometheus 10Gi, alertmanager 1Gi, grafana 1Gi, loki 10Gi, lab-postgres 20Gi.

  **Resource baseline for right-sizing.** Allocated after sync (request/limit memory, three nodes): `1296Mi(56%)/2Gi`, `1568Mi(67%)/2464Mi(106%)`, `1046Mi(45%)/2090Mi`; CPU requests `430m`/`220m`/`260m`. `kubectl top nodes` working-set memory: `2459Mi(106%)`, `2606Mi(112%)`, `1471Mi(63%)` of the 2308 MiB allocatable per node — two of three nodes ran over their own allocatable figure. Top pods by memory: grafana 589Mi, prometheus 307Mi, loki 161Mi, alloy 57–75Mi ×3.

  **OOM kills during bring-up** (container limits, not node pressure): `argocd-application-controller-0` (limit 768Mi) `OOMKilled` ×2; `cert-manager-cainjector` (limit 64Mi) `OOMKilled` ×1; `cert-manager` restarted 5+2 times with `Error`. All reached `Healthy`. Handed to SHARED-048 — no request/limit changed in this spec.

  One unrelated pod, `default/random-number-generator`, showed 6 restarts (`Completed`) — not part of this repository; noted only.

  No civo literal was changed as a result of this run: `metricsServer.enabled=true` and `kubeletInsecureTls=false` are both confirmed as the shipped values.

- 2026-09-17 — **teardown and leak check.** `PROVIDER=civo make down` exited 0: TLS material exported to SSM, the pre-teardown backup completed in 20s, 2 ExternalDNS records cleared in 45s, the LB Service was removed, and the Argo cascade completed. The civo PVC wait reported "no cnpg-system PVCs present" and "no observability PVCs present" — the cascade had already deleted them by the time the wait ran, so no "waiting for PV" line printed. This is a deviation from the plan, which expected those wait lines to print: the outcome (0 leaked volumes) is proven, but the wait code paths themselves were not exercised on this run. `cluster-down.sh`'s dangling-volume sweep reported "no leaked disposable-lifecycle resources found." Independent check against the Civo API in LON1: 0 volumes, 0 clusters. The bootstrap and persistent layers for `vk-civo-lab` were left up afterward by operator choice; nothing disposable remained.

- 2026-09-17 — **spec closed.** §§1, 3, 4, 6, 8 and 12 were corrected to match the measured facts above: 3 × Medium fixed pool, not Large; Civo ships no metrics-server; kubelet TLS verifies cleanly on civo; control-plane scrapes are plain literals, not a values key; the volume-leak defense is the layered Loki/PVC-wait/dangling-sweep mechanism, not a claim that a lifecycle-validation run had verified it (that claim was wrong — no such run happened); and the RAM risk is now measured numbers plus the OOM kills, handed to the right-sizing spec. Merged directly to `main` without a PR, at the user's request, so the status goes straight to `DONE`. All §8 acceptance criteria met.
