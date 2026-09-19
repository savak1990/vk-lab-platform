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

Terraform creates the pool at 2 nodes and then stops owning the count. The
autoscaler owns it for the life of the cluster.

## 2. Scope and non-goals

In scope:

- The install method.
- `--nodes=2:3:workers`.
- Terraform `ignore_changes`.
- The in-cluster Civo API Secret.
- Memory requests raised to match measured use, so the scheduler sees the real
  footprint.
- A ServiceMonitor for the autoscaler's metrics.
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

- `make up` creates the cluster with 2 nodes.
- **After §6 step 4's measurement and adjustment**, at least one pod is
  `Pending` for insufficient memory on the 2-node cluster. The committed
  request rises do not reach this on their own — see §4's memory budget. A
  first bring-up that settles on 2 nodes with nothing pending means step 4 is
  still outstanding, not that the autoscaler is broken.
- The autoscaler adds the third node within about 10 minutes, and the pending
  pods schedule. The elapsed time is recorded.
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
  The saving this spec's 2-node floor is meant to deliver arrives only once
  CIVO-175 reduces the real footprint. Until then the deliverable is the
  mechanism and the scale-up proof.
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
