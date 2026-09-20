---
id: "CIVO-172"
title: "Argo CD operations that can never end, and the teardown they deadlock"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "The diagnosis is done and the fixes are small; the work is shell ordering and one Helm value, plus a live teardown to prove it"
effort_estimate: "Half a session (2–3 h) plus one real up/down cycle"
estimate_confidence: "medium"
depends_on: ["CIVO-170"]
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
completed: null
---

# CIVO-172 — Argo CD stuck operations

## 1. Outcome and rationale

A transient API-server outage must not be able to wedge the platform
permanently, and a teardown must not be able to deadlock on a hook that no
longer exists. Both happened on one live run on 2026-09-20.

The root property behind both: **Argo CD has no sync-operation timeout.**
`terminate` is absent from the Application CRD in v3.5.1 (chart 10.4.0, what
`argo-up.sh` pins), and upstream issue argo-cd#6055 closed without shipping
one. An operation that waits on something which can never resolve waits
forever, and `syncPolicy.retry` never fires, because retry only applies once an
operation ends.

This matters now because CIVO-170 made node-pool resizes routine. The cluster
is created at the autoscaler's floor and the platform does not fit there, so
every bring-up scales up while Argo is mid-sync.

## 2. Scope and non-goals

In scope:

- Removing the resource that could never settle (done in CIVO-170; recorded
  here because this spec owns the reasoning).
- `argo-down.sh`: hook release before operation termination, clearing stale
  operation state, and a guarded release of a stuck Application finalizer.
- Retrying the API-reachability probe that both teardown scripts refuse on.
- A decision on the unread `api_endpoint` SSM parameter.

Not in scope: an Argo CD upgrade to obtain a sync timeout (none exists);
a `PersistentVolumeClaim` health-check override (see §4); fixing Civo's control
plane.

## 3. Current state / evidence

Observed on `vk-civo-lab`, 2026-09-20, during CIVO-170's live verification.

**Failure one — bring-up.** The API server became unreachable mid-sync.
`status.operationState.syncResult` recorded 62 resources `SyncFailed`, every
one a network error (`net/http: TLS handshake timeout`, `http2: client
connection lost`) against `10.43.0.1`, the fixed `kubernetes` ClusterIP —
which rules out endpoint churn and means the API server itself was down.
`Deployment/kube-prometheus-stack-grafana` was among them. Argo does not
re-apply a failed resource inside the same operation, so no Grafana pod
existed; its `WaitForFirstConsumer` PVC therefore never bound; Argo reads a
Pending PVC as Progressing; and with no operation timeout the sync stayed
`Running` indefinitely. CIVO-160 had passed on identical configuration three
days earlier, with no outage.

**Failure two — teardown.** `argo-down` then stalled. `kube-prometheus-stack`
held a `deletionTimestamp` with `op=Terminating` and the message `waiting for
completion of hook batch/Job/kube-prometheus-stack-admission-create`, while the
`observability` namespace was empty and no such Job existed anywhere. Argo
processes no deletion finalizer while an operation is in flight, so the whole
cascade froze — eight Applications, several minutes. Clearing the Application's
`resources-finalizer` by hand released it and the cascade drained in seconds.

**Why the two mitigations already in `argo-down.sh` did not cover it:**

- Setting `status.operationState.phase = Terminating` asks the controller to
  wind the operation down. A controller blocked on a vanished hook never
  finishes winding down, so the operation sat in `Terminating`.
- The orphaned-hook-finalizer sweep ran *after* that termination. Once Argo is
  already waiting on a hook, reaping the hook afterwards does not make it
  re-evaluate.

The hook policy comes from upstream: kube-prometheus-stack's admission-webhook
patch hooks carry `hook-delete-policy: before-hook-creation,hook-succeeded` —
the policy `CLAUDE.md` says never to use, in a chart this repository does not
control.

**No prior occurrence.** A sweep of every Civo spec's execution evidence found
no earlier instance of the Kubernetes API server being unreachable in this
project. Earlier "control plane" incidents (CIVO-055, 115, 185) were
CRD-establishment wedges with a healthy API server; CIVO-040's flakiness was
Civo's separate provisioning API.

## 4. Design and contracts

**Remove what cannot settle, rather than override its health.** Grafana was the
only PersistentVolumeClaim that Argo itself creates — Prometheus and
Alertmanager use `volumeClaimTemplate`, Loki is a StatefulSet, CNPG's volumes
are operator-created. `grafana.persistence.enabled: false` removes it.

Nothing of value is lost: dashboards and datasources are provisioned from
ConfigMaps, the admin password comes from a Secret, and alert rules are
`PrometheusRule` objects. Only ad-hoc UI state lived on that volume, and it
never survived `make down` in any case — `civo-volume` reclaims `Delete`, so
the claim dies with the cluster.

**`persistence.type: statefulset` was tried first and reverted.** It looked
strictly better — same persistence, claim created by the StatefulSet
controller, so Argo never tracks it — and it rendered cleanly. It failed in CI
on both targets. A `volumeClaimTemplate` claim outlives its StatefulSet unless
a `persistentVolumeClaimRetentionPolicy` says otherwise, and the Grafana chart
exposes no such setting and renders none. Loki avoids this only because its
chart does expose one, pinned deliberately at
`gitops/templates/platform/shared/observability/loki.yaml`
(`enableStatefulSetAutoDeletePVC: true`, `whenDeleted: Delete`, with a comment
saying it is pinned so an upstream default change cannot silently orphan the
volume). Evidence: `CLUSTER-DOWN: leaked volumes, deleting:
vol-01e4c54a8de0fa525` on the AWS leg, and on Civo the orphaned volume held the
network open — `DatabaseNetworkInUseByVolumes`. A latch was traded for a leak.

This follows ADR 0025 §6 ("a wave must never contain a resource whose health
depends on a later wave") and ADR 0016's preference for removing the trigger
over overriding a health check. A
`resource.customizations.health.PersistentVolumeClaim` override is therefore
**not** added: with no Argo-created PVC left it would guard only a bare PVC
nobody has written. If one is ever added, ADR 0025 §5's Gateway override is the
precedent — and note that core resources take no `<group>_` prefix in that key.

**`argo-down.sh` ordering and escape hatches:**

1. Disarm automated sync and drop queued operations first, so nothing new starts.
2. **Then** release orphaned Argo hook finalizers — before terminating, not
   after. Sweep one kind per query; an item's own `.kind` is populated only on
   multi-resource gets, and a wrong kind patches nothing while appearing to
   succeed.
3. Then terminate in-flight operations. If any is still non-terminal after
   `ARGO_DOWN_OP_CLEAR_DWELL` (default 60s), remove `/status/operationState`
   outright. This is Argo's documented remedy and is safer than clearing the
   Application's finalizer, because the cascade's own resource cleanup survives.
4. Sweep hooks once more immediately before the cascade; the DNS and load
   balancer waits above it take minutes.
5. Inside the cascade wait, as a last resort after `ARGO_DOWN_STUCK_APP_DWELL`
   (default 180s): release the finalizer of an Application that is deleting,
   carries **only** `resources-finalizer.argocd.argoproj.io`, and has an empty
   `status.resources`. The empty-resources test is the safety — never drop that
   finalizer while Argo still believes it owns live objects.

**The reachability probe retries.** `argo-down.sh` and `cluster-down.sh` both
refuse to proceed when `kubectl cluster-info` fails, to avoid orphaning nodes
and load balancers. Each ran that probe once with a 5s timeout. A blip there
aborts the whole teardown — and a blip is most likely right after a resize,
which is exactly when a teardown runs. `api_reachable()` in `scripts/lib/provider.sh`
retries (default 6 × 10s) before refusing, matching the reasoning already
written into `argo-up.sh`'s DNS wait: a wait loop should poll through a
transient error, not die on one.

## 5. Files/components affected

`scripts/argo-down.sh`, `scripts/cluster-down.sh`, `scripts/lib/provider.sh`,
`gitops/templates/platform/shared/observability/kube-prometheus-stack.yaml`,
`tests/golden/gitops-aws/`.

## 6. Implementation steps

1. `grafana.persistence.type: statefulset`; regenerate the golden baseline.
2. `api_reachable()` in `provider.sh`; both teardown scripts call it.
3. Reorder `argo-down.sh` per §4 and add the two escape hatches.
4. Verify on a live cluster: a full `up`, then a `down` started while a sync is
   still in flight — the case CI reaches whenever `up` fails.

## 7. Dependencies and blockers

CIVO-170 (the autoscaler is what makes resizes routine).

## 8. Acceptance criteria

- The civo render contains no `PersistentVolumeClaim`; Grafana renders as a
  StatefulSet with a `volumeClaimTemplate`, and its Service name is unchanged so
  the HTTPRoute and ServiceMonitor selectors still match.
- A teardown begun while a sync is in flight completes without manual
  intervention, and the log names whichever escape hatch fired.
- No Application needs a hand-edited finalizer.
- `make down` still refuses when the API is genuinely gone, rather than
  proceeding blind — the retry must not turn the guard off.

## 9. Validation

`make gitops-check`, `make specs-check`, `helm lint`, `kubeconform`,
`shellcheck` against the CIVO-045 baseline. Then one real `up`/`down` cycle on
`vk-civo-lab`.

## 10. AWS regression protection

`api_reachable()` is shared, so the AWS teardown path changes too: it now
tolerates a blip where it previously refused. The Grafana change is shared as
well, so the AWS golden baseline is regenerated and reviewed in the same commit.

## 11. Rollout and rollback/recovery

Each item is independent and individually revertible. The manual recovery, if
a teardown ever deadlocks again: confirm the Application's resources are gone,
then `kubectl patch application <app> -n argocd --type=merge -p
'{"metadata":{"finalizers":[]}}'`.

## 12. Risks and unresolved questions

- **The cause of the API outage is unknown.** One occurrence, no baseline in
  this project, and a node-pool resize is the leading suspect purely on timing.
  Civo's own documentation claims a replicated control plane and says nothing
  about disruption during scaling. None of the fixes here depend on the answer,
  which is the point of them.
- The escape hatches are written but not yet proven against a live wedged
  teardown; the jq selection logic is unit-tested against fixtures only.
- The SSM parameter `/<project>/cluster-civo/k8s/api_endpoint` has no readers
  and is never refreshed after a scale event, because `ignore_changes` stops
  Terraform re-applying. Harmless today, a staleness bug the moment something reads it.
  Decide: delete it, or document why it stays.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-20 — created from CIVO-170's live run, which exposed both failures.
  The fixes ship in the same change as CIVO-170 rather than waiting, because
  that spec is what makes resizes routine.
- 2026-09-20 — **teardown fixes verified in CI** (PR #35, run 35499187606,
  `lifecycle-civo / down`). All three fired and named themselves:
  `API reachable again after 3 attempts` — twice, so the API really was
  unreachable during teardown and the old single 5s probe would have refused to
  run at all and aborted the whole teardown; and
  `operation on application/{cert-manager,kube-prometheus-stack,root} did not
  wind down in 60s - dropping its stale operation state`, so reordering the
  hook sweep alone was not sufficient and the operation-state clearing was
  needed. The cascade then completed in 38s with no manual intervention, where
  the same situation locally deadlocked until a finalizer was hand-edited. The
  guarded last-resort finalizer release did not need to fire.
- 2026-09-20 — **a regression this spec introduced, found by the same run.**
  `persistence.type: statefulset` leaked Grafana's volume on teardown, on both
  targets: the AWS sweep reported `leaked volumes, deleting:
  vol-01e4c54a8de0fa525`, and the Civo network delete failed with
  `DatabaseNetworkInUseByVolumes`. Root cause: a `volumeClaimTemplate` claim
  outlives its StatefulSet without a `persistentVolumeClaimRetentionPolicy`,
  which the Grafana chart cannot set. Corrected to
  `persistence.enabled: false`. Both teardown failures in that run trace to
  this, not to the escape hatches. The lesson worth keeping: a clean
  `helm template` plus `kubeconform` proved the object graph was valid and
  said nothing about its deletion behaviour.
