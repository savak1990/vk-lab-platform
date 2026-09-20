---
id: "CIVO-170"
title: "Civo cluster autoscaler on the Medium pool, 2 to 3 nodes"
status: "IN_PROGRESS"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Upstream chart plus one Terraform lifecycle rule; the credential question is settled, the open item is the memory budget"
effort_estimate: "Half a session (2–3 h) plus scaling waits"
estimate_confidence: "medium"
depends_on: ["CIVO-030"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-20"
completed: null
---

# CIVO-170 — Cluster autoscaler

## 1. Outcome and rationale

The Civo cluster autoscaler keeps the `workers` pool between 2 and 3
`g4s.kube.medium` nodes. It adds a node when pods stay pending. It removes a
node after sustained underutilization.

Terraform creates the pool at 3 nodes and then stops owning the count. The
autoscaler owns it for the life of the cluster, within the 2..3 bounds.

## 2. Scope and non-goals

In scope:

- The install method.
- `--nodes=2:3:workers`.
- Terraform `ignore_changes`.
- The in-cluster Civo API Secret.
- Memory requests raised to match measured use, so the scheduler sees the real
  footprint.
- A ServiceMonitor for the autoscaler's metrics.
- Grafana's volume removed, so no PersistentVolumeClaim is left for Argo to
  wait on when a scale event disturbs a sync. A `volumeClaimTemplate` was tried
  first and reverted — see CIVO-172 §4.
- A scale-up test.

Not in scope: multiple pools, spot-like capacity (Civo has none), Karpenter
parity, full right-sizing of the platform (CIVO-175), proof of scale-down
(see §12).

## 3. Current state / evidence

- The upstream `cluster-autoscaler` Helm chart 9.59.0 supports
  `cloudProvider: civo`. Its default image is
  `registry.k8s.io/autoscaling/cluster-autoscaler:v1.35.0`, matching the
  cluster's pinned `kubernetes_version = "1.35.0-k3s1"`.
- `secretKeyRefNameOverride` makes the chart render no Secret of its own and
  read `api-url`, `api-key`, `cluster-id` and `region` from an externally
  created one. No token reaches Git.
- The node-group name `workers` is special to the civo cloud provider: it
  applies one min/max pair to every pool in the cluster. Correct here, because
  `terraform/modules/civo-k8s` declares exactly one pool, labelled `workers`.
- The Civo marketplace app (`civo-cluster-autoscaler`) is the rejected
  fallback: image v1.25.0, installed outside Argo CD, and its `1:10:workers`
  default is changed only by a `kubectl patch` that Argo does not own.
- CIVO-160 measured the live 3-node cluster on 2026-09-17: memory requests
  1296/1568/1046 MiB, working set 2459/2606/1471 MiB, against 2308 MiB
  allocatable per node.

## 4. Design and contracts

- Install: the upstream chart as an Argo CD `Application`,
  `gitops/templates/platform/civo/autoscaler/application.yaml`, sync wave 0.
  Wave 0 puts it after the operators and before the observability stack whose
  pending pods it must serve. It needs no Karpenter-style low wave on teardown:
  it resizes a pool Terraform owns rather than creating standalone servers, so
  reverse-wave removal ahead of the workloads leaks nothing.
- Terraform: `pools[0].node_count = 2`, and the existing `lifecycle` block
  extended to `ignore_changes = [tags, pools[0].node_count]`. Extended, not
  replaced — dropping `tags` reintroduces the Civo update-API 400 that the
  surrounding comment documents.
  Because `ignore_changes` covers it, `node_count` sets only the node count the
  cluster is born with; the autoscaler owns it from then on. Creating at the
  ceiling is the measured choice. Creating at the floor was tried first, so
  that every bring-up would exercise a real scale-up and check the autoscaler
  continuously. Three CI runs (§14) showed the cost: the platform does not fit
  on two nodes, Postgres is what pushes it over, and the scale-up therefore
  lands late in the sync — after observability is already Healthy — and depends
  on the autoscaler being able to reach a Civo API that is restarting at that
  moment (CIVO-172). Creating at 3 removes that dependency. The autoscaler
  still owns the count afterwards and still holds the 2..3 bounds, so an
  over-provisioned cluster can still shrink; it will not here, because no
  scale-down candidate exists. Whether a given run scaled is recorded, not
  assumed: `argo-up` prints the node inventory and the
  `cluster-autoscaler-status` ConfigMap on every exit path. This does give up
  coverage: a run that starts at 3 exercises no scale-up. Replacing it with an
  explicit burst in the CI `test` job — deterministic, and not dependent on the
  platform's footprint happening to exceed two nodes — is outstanding work,
  tracked in §12.
- Values: `capacity.autoscaler: {min: 2, max: 3, pool: workers}`, plumbed
  through `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, the root
  Application's `helm.parameters` and `scripts/argo-up.sh`.
- Arguments: `skip-nodes-with-system-pods: false`,
  `skip-nodes-with-local-storage: false`, `scale-down-unneeded-time: 10m`.
  Without the first two, every scale-down is blocked — `external-dns` runs in
  `kube-system` with no PodDisruptionBudget, and several platform pods mount
  `emptyDir` scratch.
- Credential: none is delivered. Civo's k3s already ships Secret
  `civo-api-access` in `kube-system`, owned by a k3s Addon and consumed by
  Civo's own CCM and CSI drivers, carrying exactly the four keys the chart
  reads. `secretKeyRefNameOverride` points at it. Nothing in this repository
  writes to it — the CSI driver needs a fifth key (`namespace`) the chart does
  not know about, so an apply that omits that key breaks volume provisioning.
  ADR 0030 is amended accordingly.
- Observability: a ServiceMonitor in
  `gitops/templates/platform/shared/observability/monitors.yaml`, civo-gated,
  wave 2, rather than the chart's own `serviceMonitor.enabled` — that one
  renders before kube-prometheus-stack installs the CRD and stamps a `release`
  selector label this platform does not use.

### The memory budget

The autoscaler schedules on **requests**, not on use. Measured requests total
3910 MiB, which fits inside two nodes' 4616 MiB, while the measured working set
totals 6536 MiB. Left alone, the autoscaler would hold the cluster at two nodes
while the real workload was 1.9 GiB over capacity — and it would not correct
itself, because an OOM-killed container restarts in place and never becomes
`Pending`.

This spec therefore raises memory requests to a little above measured use where
a pod was under-requested:

| Component | Request before | Request after | Measured use |
|---|---|---|---|
| Grafana | 400Mi (limit 512Mi) | 640Mi (limit 768Mi) | 589Mi |
| Loki | 96Mi | 192Mi | 161Mi |
| Alloy (DaemonSet) | 80Mi | 96Mi | 57–75Mi |
| argocd-application-controller | 512Mi (limit 768Mi) | 768Mi (limit 1152Mi) | OOMKilled ×2 at the old limit |

Grafana's old limit was below its own measured use. These are corrections, not
padding, and they apply to both targets.

They total about 624 MiB. That is not enough on its own to guarantee the third
node: the figure to beat on two nodes is about 3760 MiB (the 3910 MiB total
less one node's DaemonSet requests) against 4616 MiB allocatable. The remaining
gap is closed from live measurement, not from estimate — see §6 step 4.

## 5. Files/components affected

`terraform/modules/civo-k8s/main.tf`,
`gitops/templates/platform/civo/autoscaler/application.yaml`,
`gitops/templates/platform/shared/observability/{monitors,kube-prometheus-stack,loki,alloy}.yaml`,
`gitops/values.yaml`, `gitops/bootstrap/values.yaml`,
`gitops/bootstrap/templates/root-application.yaml`, `scripts/argo-up.sh`,
`scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/`.

## 6. Implementation steps

1. Terraform: node count 2, `ignore_changes` extended.
2. The Argo CD Application, the values plumbing and the ServiceMonitor.
3. No credential work: point the chart at Civo's own `civo-api-access`.
4. Bring the cluster up. Read the real per-pod requests and working set. Raise
   requests on whatever else is under-requested until the platform cannot be
   scheduled onto two nodes. Record every figure here.
5. Observe the scale-up from 2 to 3 and time it.
6. Re-apply Terraform; confirm no `node_count` and no `tags` drift.

## 7. Dependencies and blockers

030 (cluster).

## 8. Acceptance criteria

- `make up` creates the cluster with 3 nodes, and the autoscaler adopts the
  pool with bounds 2..3 rather than resizing it.
- On a cluster started at 2, at least one pod is `Pending` for insufficient
  memory and the autoscaler adds the third node within about 10 minutes. Proven
  on 2026-09-20 (§14) before the create-time count moved to 3.
- The autoscaler's log shows a `ScaleUp` naming the `workers` pool.
- A Terraform re-apply plans clean.
- `make down` leaves no dangling node or volume.

## 9. Validation

`make gitops-check`, `make specs-check`, `terraform fmt`/`validate`,
`helm lint`, `kubeconform` on both renders. Then the real cloud test above
(about 0.20 USD).

## 10. AWS regression protection

The autoscaler itself is civo-gated. The raised memory requests are shared, so
`tests/golden/gitops-aws/` is regenerated and reviewed in the same commit.

## 11. Rollout and rollback/recovery

Remove the Application and restore `node_count` to an explicit value in
`terraform/modules/civo-k8s/main.tf`.

## 12. Risks and unresolved questions

- **Scale-down is not proven by this spec.** The platform's measured working
  set does not fit two nodes, so the cluster is expected to settle at three.
  The saving the 2..3 bounds are meant to deliver arrives only once CIVO-175
  reduces the real footprint. Until then the deliverable is the mechanism and
  the scale-up proof.
- **Creating at 3 gives up the per-run scale-up check.** Replace it with an
  explicit burst in the CI `test` job: schedule a few pods large enough to not
  fit, assert a third node arrives, delete them. That is deterministic, costs
  about four minutes, and does not depend on the platform's own footprint. Not
  written yet.
- The Civo API key is account-wide and unscoped. Accepted for this
  single-operator lab. ADR 0029 and ADR 0030 already state the blast radius.
- Civo account quotas override the autoscaler's maximum.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY.
- 2026-09-06 — user decision: deferred to P3 and milestone M2, pending research
  into whether a second Civo API key was obtainable.
- 2026-09-20 — research closed. Civo API keys are account-wide and unscoped;
  multiple keys exist only across Organization sub-accounts, so a personal
  account has exactly one. The user accepted the exposure and asked to
  implement. ADR 0030's dedicated-key paragraph is corrected accordingly, and
  `decisions.md`'s option (b) is superseded.
- 2026-09-20 — bounds fixed at 2 to 3 on the Medium pool, replacing the four
  different pairs this spec previously carried. Priority raised to P2.
  Implementation started; status `IN_PROGRESS`.
- 2026-09-20 — live bring-up on `vk-civo-lab`. Terraform verified: the cluster
  created with 2 nodes. The bring-up also found a defect: the first
  implementation had `argo-up` create Secret `civo-api-access`, but Civo's k3s
  already ships a Secret of that exact name, owned by a k3s Addon
  (`/var/lib/rancher/k3s/server/manifests/api-secret.yaml`) and consumed by
  `civo-ccm` and `civo-csi-*`. The apply stamped a
  `last-applied-configuration` omitting Civo's `namespace` key, which a later
  client-side apply would have stripped, breaking CSI volume scoping. No
  damage occurred — all CCM and CSI pods stayed Running with 0 restarts, and
  the written values matched Civo's own. Fixed by deleting the Secret creation
  entirely and consuming Civo's Secret read-only.
- 2026-09-20 — **scale-up verified on the live cluster.** The autoscaler
  authenticated to the Civo API with Civo's own Secret and read its bounds:
  `found configuration for workers node group: min: 2 max: 3`. At the floor it
  refused to scale down — `node group min size reached (current: 2, min: 2)`.
  A burst of three pods requesting 1500Mi each was applied at 23:22:22Z; the
  autoscaler logged `Autoscaler loop triggered by unschedulable pod appearing`
  in the same second, and the third node reached `Ready` at about 23:24:50Z —
  roughly 2.5 minutes against the 10-minute criterion. The third burst pod
  stayed `Pending` and the autoscaler logged `Skipping node group workers - max
  size reached`, so the ceiling holds. Image `v1.35.0`, matching the cluster.
  Note: a Civo pool resize restarts the managed control plane, and the
  autoscaler pod exits when the API server goes away
  (`Failed to get nodes from apiserver ... connection refused`). It restarts
  by itself; expect a few restarts on the pod after any scaling event.
- 2026-09-20 — **scale-down verified**, which §12 had expected to defer. The
  burst was deleted at about 23:25:30Z and the autoscaler removed the third
  node at 23:35:45Z — almost exactly the configured `scale-down-unneeded-time:
  10m` — then stopped at the floor with `no scale down candidates`. Scale-down
  was observable only because `kube-prometheus-stack` never came up on this run
  (see below), so the cluster was lighter than a healthy platform. It does not
  prove the full platform fits two nodes.
- 2026-09-20 — **Terraform drift check passed.** With the live pool at 3 nodes
  and the configuration saying 2, `terragrunt plan` on `cluster-civo/k8s`
  reported `No changes. Your infrastructure matches the configuration.` The
  `ignore_changes = [tags, pools[0].node_count]` contract holds.
- 2026-09-20 — **a platform-wide deadlock found, and autoscaling makes it more
  likely.** `kube-prometheus-stack` wedged permanently. Diagnosis from
  `status.operationState.syncResult`: 62 resources reported `SyncFailed`, every
  one a network error against the API server (`net/http: TLS handshake
  timeout`, `http2: client connection lost`), including
  `Deployment/kube-prometheus-stack-grafana`. Argo does not re-apply a failed
  resource inside the same operation, so no Grafana pod existed; its
  `WaitForFirstConsumer` PVC therefore could never bind; and Argo reads a
  Pending PVC as Progressing, so the operation stayed `Running` forever and
  never retried. `WaitForFirstConsumer` is not the cause — it is the latch that
  turns a transient blip into a permanent stall. CIVO-160 passed on identical
  configuration three days earlier because no blip occurred. **The suspected
  link to this spec: the outage coincided with a pool resize.** The CI run
  below then saw an outage with no resize at all, so this is correlation, not a
  demonstrated mechanism. Upstream issue: argo-cd#12840, open
  since 2023. Fix deferred to a separate piece of work; candidates are dropping
  Grafana's PVC (dashboards already come from ConfigMaps) or a
  `resource.customizations.health.PersistentVolumeClaim` Lua override — noting
  that core resources take no group prefix in that key.
- 2026-09-20 — **the latch is removed in this spec**, because the autoscaler is
  what makes it likely to trip. Grafana was the only PersistentVolumeClaim in
  the platform that Argo itself creates: Prometheus and Alertmanager use
  `volumeClaimTemplate`, Loki uses a StatefulSet, and CNPG's volumes are
  operator-created, so Argo tracks none of them. Setting
  `grafana.persistence.enabled: false` removes the claim entirely. Verified by
  rendering the real chart with this repository's own values: zero
  `PersistentVolumeClaim` objects and zero `volumeClaimTemplates`. This follows
  the house pattern of removing what stops a wave settling, rather than
  overriding a health check. A `PersistentVolumeClaim` health override is
  therefore not needed and is not added; it would only guard a bare PVC nobody
  has written yet. Moving the claim to a `volumeClaimTemplate` was tried first
  and reverted because it leaked the volume on teardown — see CIVO-172 §4 and
  §14.
- 2026-09-20 — **first CI lifecycle run (PR #35, run 35499187606):
  inconclusive on scale-up.** `cluster-autoscaler` reached `Synced/Healthy` at
  wave 0, but `argo-up` died 6 minutes into the watch on a pre-existing silent
  exit during an API outage (CIVO-172 §3, failure three), before the
  observability wave had settled. Terraform destroyed exactly 2 nodes, so no
  scale-up happened on that run. The watch now prints the node inventory and
  autoscaler status on every exit, so the next run records the answer either
  way.
- 2026-09-20 — **second CI lifecycle run (PR #35, run 35504051183): scale-up
  proven in CI, whole run green on both targets.** `lifecycle-civo / up`
  finished Synced/Healthy at 10:47:33 with **3 nodes**; the third joined at
  about 10:41 (age 6m39s at the final inventory), and the autoscaler's status
  ConfigMap showed `scaleUp: NoActivity` with a transition at 10:44:21, i.e. a
  scale-up that had completed. So the platform's committed requests do not fit
  on two nodes after all, and the floor-of-2 contract does exercise the
  autoscaler on every bring-up. Not captured this time: the `TriggeredScaleUp`
  events came back empty and the log grep matched only the provider's 10s
  `adding node pool` cache refresh, so the exact trigger time is inferred from
  the node age. Both capture defects are fixed for the next run (events read by
  the status ConfigMap's involvedObject, refresh line excluded). The earlier
  local evidence quoting `adding node pool` as the scale-up marker was that
  same refresh line; `max size reached` was the real signal there.
- 2026-09-20 — **create-time count moved from 2 to 3, and why.** Two further CI
  runs (35509187271, 35509916494) were green and both scaled to 3, so the
  floor-of-2 contract worked. They also showed what it costs. Observability
  fits on two nodes — `kube-prometheus-stack` reached Healthy at 13:25:21 in
  the second run — and the last resource root waited on was
  `Cluster/lab-postgres`. So Postgres is what needs the third node, the
  scale-up lands late in the sync, and it depends on the autoscaler reaching a
  Civo API that is restarting at that moment (CIVO-172): the node was created
  at 13:28:41, 71 seconds after the third outage ended. Baseline for the
  comparison, from that run: `argo-up` started 13:09:57, the watch at 13:11:11,
  the third node at 13:28:41, platform ready 13:36:13, whole job 35m06s. The
  expected saving from starting at 3 is the autoscaler's reaction plus the node
  boot and join, not the whole 17 minutes before the node, because most of that
  was outages and Argo retries which are unaffected.
