# CIVO-160 Observability on Civo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use `- [ ]`.
> On approval, copy this plan to `docs/superpowers/plans/2026-09-16-civo-160-observability-on-civo.md` (repo convention) in Task 1's commit.

**Goal:** Run the AWS observability stack (kube-prometheus-stack, Loki, Alloy, metrics-server, monitors, alerts, dashboards, Grafana route and admin secret) on the civo target with no change to AWS output except the reviewed Loki PVC delete policy.

**Architecture:** Move `gitops/templates/platform/aws/observability/*` to `shared/observability/`. Replace the whole-file `aws` gate with `ne target "local"`. Handle target differences with `_helpers.tpl` helpers that derive from `.Values.target`. Do not add `--set` flags: civo `argo-up` does not forward `storage.*`/`capacity.*`, and Helm deep-merges values (the same reason `values.yaml:65-67` gives for postgres).

**Tech stack:** Helm templates under Argo CD, bash (`argo-up.sh`, `argo-down.sh`, `gitops-render-check.sh`), Civo k3s 3 × `g4s.kube.medium`.

**Spec:** `specs/civo/160-observability-on-civo/spec.md`

## Context

Spec 160 is READY and its dependencies (050, 100) are DONE. Exploration found these facts, and the spec text is wrong about some of them:

- The cluster is **3 × Medium** (`terraform/modules/civo-k8s/main.tf`), not a Large pool. Allocatable memory is 2308 MiB per node (CIVO-020). Observability requests total about 1.9 GiB; Prometheus alone requests 768Mi.
- Spec 030 did **not** remove Civo's metrics-server. A later run saw no metrics-server pod. Check the cluster before you deploy one.
- Spec 150 did **not** verify volume deletion. A Civo volume keeps billing after the cluster is gone if its PVC survives. The Loki StatefulSet has no `persistentVolumeClaimRetentionPolicy`.
- Templates already use `.Values.storage.className` and `.Values.capacity.spotAvoidance`, but on civo those values stay at the AWS defaults (`ebs-delete`, `true`).
- Only the CNPG and Karpenter dashboards exist. There is no Envoy or Argo dashboard.
- The kube-prometheus-stack kubelet ServiceMonitor skips TLS verification by chart default, so `kubeletInsecureTls` affects metrics-server only.

User decisions (2026-09-16):
1. Dashboards: **amend the spec**. §8 requires the CNPG dashboard, plus Argo and Envoy metrics that you can query in Grafana Explore. New dashboards go to a later spec.
2. Leaked volumes: **fix in 160, using the AWS mechanism.** The AWS mechanism has three layers: (a) the Argo cascade deletes the PVCs (StatefulSet `whenDeleted: Delete`); (b) the `cluster-down.sh` tagged-volume sweep deletes the leaks and fails the run (`LEAK_COUNT`). Civo already has (b) as the `--dangling` sweep (`cluster-down.sh:73-85`), plus (c) a civo-only PVC wait in `argo-down.sh:310-324` for `cnpg-system`. This plan closes gap (a) for Loki on both targets and extends (c) to `observability`.

## Global constraints

- AWS golden diff must be empty, except the Loki PVC delete policy in Task 2. Never run `gitops-render-check.sh update` to hide any other diff.
- No retention or PVC size change: 10Gi Prometheus, 1Gi Alertmanager, 1Gi Grafana, 10Gi Loki.
- No Tempo/OTel collector (ADR 0018). Civo's `otel-collector` DaemonSet in `kube-system` **runs beside** this stack: it is a k3s addon, and k3s reverts edits to addon objects.
- Control-plane scrapes (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy`) stay `false` on both targets as literals. No `observability.controlPlaneScrapes` key; the Hetzner spec adds it when a target needs `true`.
- Value keys use the names in the Hetzner 160 spec: `observability.kubeletInsecureTls`, `observability.metricsServer.enabled`. That overrides `observability.k3s` in `specs/civo/architecture.md:77`; update that line.
- Code comments: at most 3 lines, no spec/ADR references (CLAUDE.md).
- Branch `civo-160-observability`; commit prefix `civo-160:`; spec-only commits use `spec(civo-160):`.

---

### Task 1: Render check expresses the civo target (test first)

**Files:** Modify `scripts/gitops-render-check.sh:52-128`

- [ ] Split `FORBIDDEN_OBJECTS` into `FORBIDDEN_OBJECTS_LOCAL` (keeps the four Grafana objects) and nothing for civo; select it in the `case` in `verify_object_set`.
- [ ] Remove `kube-prometheus-stack loki metrics-server alloy` from `FORBIDDEN_APPLICATIONS_CIVO`.
- [ ] Add to `REQUIRED_OBJECTS_CIVO`: `Application__argocd__kube-prometheus-stack Application__argocd__loki Application__argocd__alloy HTTPRoute__observability__grafana ExternalSecret__observability__grafana-admin-credentials BackendTrafficPolicy__observability__grafana-traffic-policy RoleBinding__observability__e2e-test-readonly PodMonitor__cnpg-system__cnpg-postgres ServiceMonitor__argocd__argocd`.
- [ ] Add `FORBIDDEN_OBJECTS_CIVO="ServiceMonitor__kube-system__karpenter ConfigMap__observability__dashboard-karpenter-capacity"`.
- [ ] Add a content check for civo: non-comment lines must not contain `ebs-delete` or `karpenter.sh/capacity-type`, and `PrometheusRule__observability__observability-alerts.yaml` must not contain `Karpenter`:
  ```bash
  if grep -rhv '^\s*#' "$dir" | grep -q -e 'ebs-delete' -e 'karpenter.sh/capacity-type'; then
    echo "GITOPS-RENDER-CHECK: target=$target renders an aws-only storage class or spot affinity" >&2; return 1
  fi
  ```
- [ ] Run `make gitops-check`. Expected: **FAIL**, `target=civo is missing required object Application__argocd__kube-prometheus-stack`.
- [ ] Commit `civo-160: render check requires the observability stack on civo`.

### Task 2: Hoist and template the observability files

**Files:**
- Move: `gitops/templates/platform/aws/observability/*.yaml` → `gitops/templates/platform/shared/observability/` (`git mv`)
- Modify: `gitops/templates/_helpers.tpl`, `gitops/values.yaml`
- Modify: `shared/envoy-gateway/httproutes.yaml:25-48`, `shared/rbac/e2e-test-readonly.yaml:52-71`
- Move: `BackendTrafficPolicy grafana-traffic-policy` from `aws/envoy-gateway/policies.yaml` into `shared/observability/grafana-traffic-policy.yaml`, but only if its content has no AWS-specific fields. Otherwise gate it inline.
- Modify: `specs/civo/architecture.md:77`

Steps:
- [ ] Add helpers to `_helpers.tpl`:
  ```yaml
  {{- define "platform.spotAvoidance" -}}
  {{- and (eq .Values.target "aws") .Values.capacity.spotAvoidance -}}
  {{- end -}}
  {{- define "platform.kubeletInsecureTls" -}}
  {{- if eq .Values.target "civo" -}}false{{- else -}}{{ .Values.observability.kubeletInsecureTls }}{{- end -}}
  {{- end -}}
  {{- define "platform.metricsServerEnabled" -}}
  {{- if eq .Values.target "civo" -}}true{{- else -}}{{ .Values.observability.metricsServer.enabled }}{{- end -}}
  {{- end -}}
  ```
  The civo literals are the values to test first. Task 4 changes them to the measured result.
- [ ] Add `observability: {kubeletInsecureTls: true, metricsServer: {enabled: true}}` to `gitops/values.yaml`.
- [ ] In every moved file, change line 1 `{{- if eq .Values.target "aws" }}` to `{{- if ne .Values.target "local" }}`.
- [ ] Change `{{ .Values.storage.className }}` → `{{ include "platform.storageClassName" . }}` (kube-prometheus-stack L68/L99/L107, loki L71).
- [ ] Change `{{- if .Values.capacity.spotAvoidance }}` → `{{- if eq (include "platform.spotAvoidance" .) "true" }}` (6 blocks).
- [ ] `metrics-server.yaml`: gate the file with `platform.metricsServerEnabled`, and render `--kubelet-insecure-tls` only when `platform.kubeletInsecureTls` is `"true"`. The comment says both providers' kubelet certs are not verifiable by default.
- [ ] Rewrite the control-plane comment (kube-prometheus-stack L150) to cover both targets. Example: "Neither managed control plane exposes these: EKS hides them, k3s binds them to localhost off-pool."
- [ ] Wrap the Karpenter entries in `{{- if eq .Values.target "aws" }}`: `monitors.yaml` L8-22, `alerts.yaml` L44-58, `dashboards.yaml` L7-48.
- [ ] Loki PVC delete policy (both targets): run `helm show values grafana/loki --version 7.3.0 | grep -n -i "autodeletepvc\|persistentVolumeClaimRetentionPolicy"`, then set the chart's own key so the StatefulSet has `whenDeleted: Delete`. Do not guess the key name.
- [ ] Open the gates in `httproutes.yaml` and `e2e-test-readonly.yaml` to `ne target "local"`, and delete the "aws-only until CIVO-160" comments.
- [ ] Run `make gitops-check`. Expected: civo/local structure **PASS**. AWS golden diff shows only the Loki values change inside `Application__argocd__loki.yaml`. Review that diff, then run `./scripts/gitops-render-check.sh update` for that one change. Run `make gitops-check` again and expect `aws render matches the golden baseline.`
- [ ] Run kubeconform on the aws and civo renders (commands from `.github/workflows/lifecycle-test.yml:160-195`; `brew install kubeconform` first). Expected: 0 errors.
- [ ] Commit `civo-160: hoist the observability stack to shared with target helpers`.

### Task 3: Teardown and bring-up scripts cover observability

**Files:** Modify `scripts/argo-down.sh:310-324`, `scripts/argo-up.sh` (`civo_wait_for_dns`, L215-236)

- [ ] Change the civo PVC wait to loop over `cnpg-system observability`, with the same timeout, warning text, and sweep reference:
  ```bash
  for pvc_ns in cnpg-system observability; do
    if [ -n "$(kubectl get pvc -n "$pvc_ns" -o name 2>/dev/null)" ]; then
      echo "ARGO-DOWN: waiting for $pvc_ns PVCs to finish deleting..."
      kubectl wait --for=delete pvc -n "$pvc_ns" --all --timeout="$PVC_WAIT_TIMEOUT" || echo "ARGO-DOWN: WARNING - $pvc_ns PVCs still present ..." >&2
    else
      echo "ARGO-DOWN: no $pvc_ns PVCs present - nothing to wait on."
    fi
  done
  ```
- [ ] Make `civo_wait_for_dns` check `grafana.$LAB_FQDN` as well as `argo`. Reuse `DNS_HOST_LABELS` if the function can take it.
- [ ] Run `bash -n scripts/argo-down.sh scripts/argo-up.sh`, and `shellcheck` if you install it.
- [ ] Commit `civo-160: wait for observability PVCs and the grafana record on civo`.

### Task 4: Real-cloud run on civo (about 1.5 h, about 0.3 USD)

Pre-flight: each check takes under 1 minute, and each can stop the run before it costs money.
- [ ] Run `aws ssm get-parameter --name /<project>/persistent/grafana/admin_password --profile viacheslav-dev --region eu-west-1 --query Parameter.Name`. It must exist for the civo project.
- [ ] Run `PROVIDER=civo make cluster-up`, then `PROVIDER=civo make kubeconfig`. If the persistent stack is absent, bring it up first.
- [ ] With the API reachable but before Argo CD installs anything, inspect:
  - `kubectl get apiservice v1beta1.metrics.k8s.io -o yaml` and `kubectl -n kube-system get deploy metrics-server`. If Civo already ships metrics-server, set the civo literal in `platform.metricsServerEnabled` to `false`.
  - `kubectl -n kube-system get ds otel-collector -o yaml | grep -iE 'hostPort|hostNetwork'`, checking for a port-9100 clash with the node-exporter that kube-prometheus-stack installs next.
  - `kubectl describe nodes | grep -A8 "Allocated resources"`, the baseline for all 3 nodes.
  - `kubectl -n kube-system get ds otel-collector -o jsonpath='{.spec.template.spec.containers[*].resources}'`.
- [ ] If `platform.metricsServerEnabled` changed, commit that change (`civo-160: disable metrics-server on civo, already shipped`).
- [ ] Run `git push -u origin civo-160-observability` (needed even with no literal change - `TARGET_REVISION=civo-160-observability` resolves against the pushed branch), then `PROVIDER=civo TARGET_REVISION=civo-160-observability make argo-up`.

Verify (spec §8):
- [ ] Wait for `ARGO-UP: root Synced/Healthy and DNS resolved - platform ready.` That message covers only the root Application; it does not prove any child's health. Run `kubectl get applications -n argocd` and confirm every child Application is Synced/Healthy before trusting root.
- [ ] `kubectl get pods -n observability` and `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server` (if enabled) must show all pods Ready.
- [ ] `kubectl top nodes` must work. If metrics-server logs show `x509`, set the civo `platform.kubeletInsecureTls` literal to `true`, push, re-sync, and record both results.
- [ ] `curl -k https://grafana.civo.<root-domain>/api/health` must return 200. A basic-auth call to `/api/dashboards/home` with the ESO Secret password must also return 200.
- [ ] In the Grafana CNPG dashboard, `cnpg_collector_up{cluster="lab-postgres"}` must be 1. In Explore, `up{job=~".*argocd.*"}` and `up{namespace="envoy"}` must return series. In Loki Explore, `{namespace="cnpg-system"}` must return lines.
- [ ] Record the up/down state of the kubelet, cAdvisor, node-exporter and control-plane targets from Prometheus `/api/v1/targets`.
- [ ] Record `kubectl describe nodes` Allocated resources after sync, plus `kubectl top pods -n observability`, for CIVO-175.
- [ ] If Prometheus stays Pending: record the node allocation figures above, finish every other check that doesn't depend on Prometheus, then proceed straight to teardown. Leave spec 160 `status` short of `DONE` and hand the sizing question to CIVO-175 rather than changing requests here.

Teardown and leak proof:
- [ ] Run `PROVIDER=civo make down`. The log must show `waiting for observability PVCs to finish deleting`, the new `waiting for PV ... (civo volume) to finish deleting` line for each observability/cnpg-system PV, and no WARNING.
- [ ] `cluster-down` must report no `leaked Civo dangling volume(s)`, and `civo volume ls` must show no observability volume.
- [ ] If a civo literal changed during the run, commit that change as `civo-160: set civo kubelet TLS / metrics-server to the measured result`. Run `make gitops-check` again.

### Task 5: Spec bookkeeping

**Files:** `specs/civo/160-observability-on-civo/spec.md`, `specs/civo/README.md`, `specs/civo/decisions.md` §4, specs 175/170 cross-references if they are wrong

- [ ] Amend spec §1, §3, §4, §6 step 3, §8 and §12 with the corrected facts from Context: 3 × Medium, metrics-server state, the dashboard amendment, the volume-leak mechanism, the otel-collector choice, and kubelet TLS.
- [ ] Add a §14 evidence entry in the style of spec 120, using `<root-domain>`. Include the scrape-target table, the RAM baseline and after-sync figures, and the leak check output.
- [ ] Set front matter `status: "DONE"`, `updated`/`completed: 2026-09-XX`. Tick §13, change the README index row to DONE, and re-check that 175's `blocked_by` still lists 170.
- [ ] Commit `spec(civo-160): record the civo observability run and close the spec`. Open a PR with the attribution footer.

## Verification summary

| Check | Command | Pass condition |
|---|---|---|
| AWS no regression | `make gitops-check` | `aws render matches the golden baseline.` (only the reviewed Loki diff was accepted) |
| Civo/local structure | `make gitops-check` | `civo and local renders have the expected M1 object set.` |
| Schema | kubeconform, aws and civo renders | 0 invalid |
| Scripts | `bash -n` | exit 0 |
| Cloud | Task 4 | all pods Ready, Grafana 200, CNPG dashboard populated, Argo/Envoy/Loki queries return data, no leaked volume |

## Risks

- Prometheus (768Mi) cannot schedule because of per-node DaemonSet load. Pre-flight gets the baseline. If it stays Pending, record the fact and do not change the requests; right-sizing belongs to CIVO-175.
- Civo already serves the metrics APIService. The pre-flight check detects this, and the helper literal disables ours.
