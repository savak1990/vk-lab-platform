---
id: "LOCAL-070"
title: "Observability stack on local with laptop-sized retention and PVCs"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Gate changes plus a handful of values; the only judgment is the memory budget"
effort_estimate: "One session (3–4 h)"
estimate_confidence: "medium"
depends_on: ["LOCAL-040", "LOCAL-050"]
blocked_by: []
supersedes: ["spec 022 Req 16"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-070 — Observability stack on local with laptop-sized retention and PVCs

## 1. Outcome and rationale

kube-prometheus-stack, Loki, Alloy, and metrics-server run on the local cluster with retention and volumes sized for a laptop, and Grafana is
reachable at `http://grafana.localhost:8080` (through `make local-forward`) with the admin password from
`secrets/`. The stack is already cloud-free (Loki filesystem single-binary,
no object store, no Tempo); it is only gated `aws` and reads three
aws-shaped values. Keeping it on local preserves the Grafana e2e test and
gives developers the same dashboards they get in the cloud.

## 2. Scope and non-goals

In scope:
- Change every `aws/observability/*` Application gate from `eq "aws"` to
  `or (eq "aws") (eq "local")` (or `ne "civo"` while CIVO-160 is pending —
  pick the form that keeps the civo render unchanged).
- Local values (via `argo-up` `--set` or a `local` block in the
  Application template): `prometheus.retention: 2d`,
  `prometheus.retentionSize: 1GB`, PVC 2Gi; `alertmanager.enabled: false`;
  Grafana `persistence.enabled: false`; Loki PVC 2Gi,
  `chunksCache.enabled: false`, `resultsCache.enabled: false`.
- `capacity.spotAvoidance=false` already passed by LOCAL-010 disables the
  `karpenter.sh/capacity-type` affinities.
- `grafana-admin-secret.yaml` (ExternalSecret) gated off for local; the
  `argo-up` Secret from LOCAL-010 has the same name and keys.
- Alerts/dashboards/monitors Applications: keep; alert rules that reference
  NLB/Karpenter stay inert.
- Render-check: observability Applications move from forbidden to required
  for local.

Not in scope:
- Tempo, OTel Collector (not deployed anywhere).
- Control-plane scrapes (`kubeControllerManager`, `kubeScheduler`,
  `kubeEtcd`) — stay disabled; on kind they bind loopback.
- Civo observability (CIVO-160).

## 3. Current state / evidence

- `aws/observability/kube-prometheus-stack.yaml:55-64,86-95,125-134`
  spot-avoidance affinities; `:65-72,96-103,105-108` PVCs on
  `.Values.storage.className` (raw); `:150-158` control-plane scrapes
  disabled.
- `aws/observability/loki.yaml:22-45` SingleBinary filesystem; `:59-68`
  affinity; `:69-72` PVC.
- `aws/observability/grafana-admin-secret.yaml:26` ExternalSecret from SSM.
- `aws/observability/metrics-server.yaml:39-40` `--kubelet-insecure-tls`
  (also needed on minikube/kind). minikube's `metrics-server` addon, if
  enabled, collides with the Argo app; LOCAL-110 says to leave it off.
- `scripts/gitops-render-check.sh:76-78` forbids these Applications for
  local.
- Research budget: trimmed stack ~2–3 GB.

## 4. Design and contracts

Namespace `observability` is created by `argo-up` before the root
Application (LOCAL-010) so the Secret exists on first sync.

Values source: prefer `--set` from `argo-up` for the few scalars
(retention, sizes, alertmanager) so the templates gain no new branches;
use a template branch only where a whole block differs (persistence off).

Memory target after this spec: total cluster requests ≤ 4 GB on an idle
platform (`kubectl top nodes` recorded in §14).

## 5. Files/components affected

`gitops/templates/platform/aws/observability/*.yaml` (gates and value
plumbing); `gitops/values.yaml` (documented local defaults);
`scripts/argo-up.sh` (`--set`s); `scripts/gitops-render-check.sh`.

## 6. Implementation steps

1. Gates; golden diff must stay empty (aws values unchanged).
2. Local values plumbing; render-check lists.
3. `PROVIDER=local make up`; all observability Applications `Healthy`.
4. `curl --resolve grafana.localhost:8080:127.0.0.1
   http://grafana.localhost:8080/api/health` → 200; authenticated
   `/api/dashboards/home` with the admin password.
5. `kubectl top nodes` and `kubectl get pvc -A` recorded.

## 7. Dependencies and blockers

LOCAL-040 (`local-retain` for the PVCs), LOCAL-050 (grafana route).

## 8. Acceptance criteria

- Local render includes the observability Applications and no
  `ExternalSecret`.
- Grafana health and authenticated dashboard call succeed.
- Prometheus, Loki PVCs are 2Gi on `local-retain`; Grafana has no PVC;
  no Alertmanager pod.
- Idle requests ≤ 4 GB; AWS golden diff byte-identical; civo diff empty.

## 9. Validation

Offline: `make gitops-check`. Workstation: steps 3–5.

## 10. AWS regression protection

Golden diff; aws values untouched.

## 11. Rollout and rollback/recovery

Revert; observability PV directories on the node can be deleted freely
(no data of value).

## 12. Risks and unresolved questions

- A cluster below 6 GB: Prometheus is the first pod to be evicted.
  LOCAL-110 documents the minimum; `cluster-up` warns when the node's
  allocatable memory is below it.
- Observability PVCs also land under `/var/lib/vk-local-lab/observability/`
  on the node and survive `make down`; they are small and harmless.

## 13. Definition of done

- [ ] Gates and values landed; render-check updated
- [ ] Grafana reachable and authenticated; memory recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-040, LOCAL-050).
- 2026-09-11 — replanned wording for a developer-owned cluster.
