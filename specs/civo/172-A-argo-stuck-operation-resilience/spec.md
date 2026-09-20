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

The root property behind both: **this platform runs Argo CD with no
sync-operation timeout.** Argo CD does ship one — the controller-wide
`controller.sync.timeout.seconds` in `argocd-cmd-params-cm`, added in v2.14 by
PR argo-cd#20816 (which closed argo-cd#6055) and present in v3.5.1
(`controller/appcontroller.go`, "Terminating in-progress operation due to
timeout") — but it defaults to `0`, off, and `argo-up.sh` does not set it. The
per-Application `syncPolicy.terminate` is still only a proposal and is absent
from the CRD. So, as deployed, an operation that waits on something which can
never resolve waits forever, and `syncPolicy.retry` never fires, because retry
only applies once an operation ends. An earlier revision of this spec said no
timeout exists at all; that was wrong, and §12 records the follow-up.

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
- `argo-up.sh`'s root watch: surviving an API blip instead of dying silently,
  and logging enough on every exit path to diagnose the next failure from the
  CI log alone.
- A decision on the unread `api_endpoint` SSM parameter.

Not in scope: enabling `controller.sync.timeout.seconds` — it exists, but a
timed-out operation ends `Failed`, and a child Application with no
`syncPolicy.retry` is then wedged for that revision, so every child needs a
retry budget first (§12); a `PersistentVolumeClaim` health-check override (see
§4); fixing Civo's control plane.

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

**Failure three — CI bring-up died silently.** PR #35's first lifecycle run
(35499187606, `lifecycle-civo / up`, 2026-09-20) printed its last status at
08:39:11, nothing for 2m28s, then `make: *** [Makefile:208: argo-up] Error 1`
at 08:41:39 — about 6 minutes into a 45-minute watch, with neither of the
script's two failure messages. The teardown job that followed started at
08:42:03 and its first API probe only succeeded at 08:44:04, so the Civo API
server was unreachable across the moment `up` died. The only exit path that
prints nothing is `set -e` on an unguarded command substitution:
`pending="$(pending_resources)"` piped `kubectl ... 2>/dev/null` into `jq`
under `pipefail`, so a kubectl failure became a silent exit 1. The line
directly above it was guarded with `|| true`; this one was not. It predates
CIVO-170 (2026-08-24) and was reached because this branch made an API blip
during the watch likely for the first time. The same unguarded shape existed
at three other points: `print_app_status` in the same loop, the stored-TLS
expiry pipeline in `civo_import_tls_secret` (Civo-only, runs before Argo CD is
installed), and the new hook sweep in `argo-down.sh`. The CI cluster held
exactly 2 nodes at teardown: the autoscaler never resized the pool on that
run, so the outage happened with no resize in flight.

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

**The root watch survives a blip and says so.** The watch loop moves out of
`argo-up.sh` into `scripts/lib/argo-watch.sh` as `argo_watch_root`, which
reads root once per poll and treats a failed read as an API blip: it prints
`API unreachable ... keeping the watch alive` once, keeps the last known state
so a blip cannot flip the change detector, and prints `API reachable again
after Ns` on recovery. The 2700s ceiling is the only limit on an outage. Every
line carries `[+Ns]` elapsed time, and a heartbeat (default 60s,
`ARGO_UP_HEARTBEAT_SECONDS`) prints while nothing changes, so a silent log can
only mean the script itself is gone. State changes also print root's
`status.conditions` (where Argo puts `SyncError` and `ComparisonError`), and
every exit path — success, failed sync, ceiling — prints the node inventory
and, on Civo, the `cluster-autoscaler-status` ConfigMap plus the
`TriggeredScaleUp` and `ScaledUpGroup` events and the autoscaler's own
scale-up log lines, so each CI run records whether the pool scaled and when
the autoscaler decided to. Events expire after about an hour, so they are read
during the run rather than afterwards. A failed sync or the ceiling additionally
dumps Pending pods, the last `FailedScheduling` events, root's `SyncFailed`
resources with their messages, and the autoscaler log tail. All of it is
covered by `tests/scripts/argo-watch-test.sh` against a fake `kubectl`
(`make argo-watch-check`, run by CI's validation job), including the blip case
that CI hit.

**An outage is characterised, not just counted.** On every failed poll the
watch prints kubectl's own error text (a connect timeout, a refused
connection, a TLS handshake timeout and an HTTP 5xx each name a different
failure) and a `curl` probe of `/livez` and `/readyz` with HTTP code and
timing, which separates a dead host from a live one that cannot answer. At
the first failure and again on recovery it prints Civo's own view of the
cluster (`civo kubernetes show`: status, ready flag, target node count and
per-instance status), so a Civo-side operation on the cluster shows up. On
recovery it compares the API server's `process_start_time_seconds` and the
`kube-system` lease holders with a snapshot taken at watch start — either
changing proves the control plane restarted, both unchanged means it did
not — and prints any failing `/readyz?verbose` check. Each heartbeat carries
`apiserver_current_inflight_requests`, so load before an outage is on record.

**Scale-up is timed from the objects, not from the log.** Every poll reads the
node list and the autoscaler's status ConfigMap. A new node is announced with
its `creationTimestamp`, its readiness with the Ready condition's transition
time, and the ConfigMap's cluster-wide `scaleUp` block marks the trigger with
its `lastTransitionTime` plus the Pending pods at that moment. On exit a
one-line timeline joins the three: triggered, registered after N seconds,
Ready after M seconds. The three other unguarded pipelines are guarded with `|| true`,
which in each case falls through to the behaviour already written for
"nothing found".

**The reachability probe retries.** `argo-down.sh` and `cluster-down.sh` both
refuse to proceed when `kubectl cluster-info` fails, to avoid orphaning nodes
and load balancers. Each ran that probe once with a 5s timeout. A blip there
aborts the whole teardown — and a blip is most likely right after a resize,
which is exactly when a teardown runs. `api_reachable()` in `scripts/lib/provider.sh`
retries (default 6 × 10s) before refusing, matching the reasoning already
written into `argo-up.sh`'s DNS wait: a wait loop should poll through a
transient error, not die on one.

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/lib/argo-watch.sh` (new),
`tests/scripts/argo-watch-test.sh` (new), `Makefile`,
`.github/workflows/lifecycle-test.yml`, `scripts/argo-down.sh`,
`scripts/cluster-down.sh`, `scripts/lib/provider.sh`,
`gitops/templates/platform/shared/observability/kube-prometheus-stack.yaml`,
`tests/golden/gitops-aws/`.

## 6. Implementation steps

1. `grafana.persistence.type: statefulset`; regenerate the golden baseline.
2. `api_reachable()` in `provider.sh`; both teardown scripts call it.
3. Reorder `argo-down.sh` per §4 and add the two escape hatches.
4. Verify on a live cluster: a full `up`, then a `down` started while a sync is
   still in flight — the case CI reaches whenever `up` fails.
5. Move the root watch into `scripts/lib/argo-watch.sh`, test-first against a
   fake `kubectl`; guard the three other unguarded pipelines.

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
- An API blip during the root watch is logged and survived, never a silent
  exit; `make argo-watch-check` proves it without a cluster.
- Every `argo-up` exit path prints the node inventory and the autoscaler
  status, so a CI log alone shows whether the pool scaled.

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

- **The API outages are Civo control-plane restarts, and the autoscaler is not
  the cause.** Measured on 2026-09-20 (§14): the API server's
  `process_start_time_seconds` changed across two of three outages in one run,
  and `kube-controller-manager`, `cloud-controller-manager` and
  `cert-manager-cainjector` all re-acquired their leases at that same moment.
  Every outage in all three CI runs happened *before* the third node existed,
  so a node-pool resize cannot explain them. What remains unknown is what
  restarts the Civo control plane; in-flight requests peaked at 15 mutating and
  23 read-only, far below k3s defaults, so the API server was not shedding
  load — it was dying and coming back. Memory pressure from Argo's parallel
  applies is the leading suspect and only Civo can confirm it. None of the
  fixes here depend on the answer, which is the point of them.
- **Follow-up: the sync timeout.** `controller.sync.timeout.seconds` (§1) is
  the structural fix for failure one — a timed-out operation ends `Failed`, so
  `syncPolicy.retry` fires and the `SyncFailed` resources get a fresh apply.
  Enabling it is a separate change because it is controller-wide: every child
  Application then needs its own `syncPolicy.retry` (today only `root` has one),
  the value must exceed the slowest legitimate sync, and `retry.refresh: true`
  should come with it so a retry follows a newer commit. The upstream note that
  the timer fires on the next operation-queue pass, not at the deadline, is
  fine for a bring-up ceiling of 45 minutes.
- **Follow-up: Argo CD's own controller is evictable by the autoscaler.** Only
  the autoscaler pod carries `safe-to-evict: "false"`; a scale-down can move
  `argocd-application-controller` mid-operation, which is exactly the
  stale-`Running` state this spec cleans up. The autoscaler only removes a node
  whose pods fit elsewhere, so this is disruption, not a livelock. A
  `controller.podAnnotations` entry in `argo-up.sh` closes it.
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
- 2026-09-20 — **the `up` leg of the same run, diagnosed** (§3, failure
  three): a pre-existing silent exit in the root watch, triggered by an API
  outage that the following `down` job independently recorded. Not a deadlock,
  not caused by the CIVO-170 or CIVO-172 changes, but made reachable by them.
  Fixed by moving the watch into `scripts/lib/argo-watch.sh` with a blip
  tolerance, heartbeat and diagnostics dump, proven by
  `tests/scripts/argo-watch-test.sh` (the blip scenario failed before the
  library existed and passes after). The same pass corrected this spec's claim
  that Argo CD has no sync timeout (§1) and recorded the two follow-ups in §12.
- 2026-09-20 — **second CI run (35504051183): the watch survived three API
  outages and the whole run was green on both targets.** `lifecycle-civo / up`
  logged `API unreachable` at +165s, +485s and +615s, recovering after 50s,
  55s and 20s; root needed 6 retries and reached Synced/Healthy at +1045s.
  The first run's identical outage had killed the script in 2 minutes. What
  the timeline says about cause: the third node joined at about 10:41, so the
  first two outages (10:27, 10:35) happened with the pool untouched at 2
  nodes — the autoscaler cannot have caused them. Only the third (10:39, 20s)
  overlaps the scale-up request, and it also follows a root retry by 75s. Every
  outage across all three runs sits inside Argo apply activity: the wave-1
  kube-prometheus-stack apply, or a root retry re-applying it. Control-plane
  load from the sync burst is therefore the leading hypothesis, not the node
  resize; still unproven. Teardown saw no outage; the stale-operation hatch
  fired once on root (a sync had restarted after bring-up), the cascade
  finished in 41s and the leak sweep found nothing.
- 2026-09-20 — **the outage is a control-plane restart, and the autoscaler is
  ruled out** (runs 35509187271 and 35509916494, both fully green on both
  targets). The second of those carried the new diagnostics and recorded three
  outages, each with the same shape: `net/http: TLS handshake timeout` with no
  answer to a 5s `curl`, then HTTP 503 `the server is currently unable to
  handle the request` in about 0.3s, then healthy. One variant went
  `i/o timeout` then `connection refused` in 0.08s, a closed port. Across those
  three, `process_start_time_seconds` was unchanged once and changed twice, and
  on both changes the `kube-controller-manager`, `cloud-controller-manager` and
  `cert-manager-cainjector` lease holders re-acquired together. So one outage
  was a stall and two were restarts. **All three finished before the third node
  was created at 13:28:41**, and the same ordering holds in the two earlier
  runs, which settles the resize hypothesis: the autoscaler is not involved.
  In-flight requests peaked at 15 mutating and 23 read-only, so this is a crash
  and not load shedding.

  | Outage | Window (UTC) | Duration | Control plane |
  |---|---|---|---|
  | 1 | 13:14:54–13:17:00 | 126s | did not restart |
  | 2 | 13:22:27–13:24:42 | 135s | restarted |
  | 3 | 13:26:50–13:27:30 | 40s | restarted |

  Both runs' teardowns were clean: no outage, no escape hatch, no leaks.
- 2026-09-20 — **a capture gap this run exposed: the autoscaler erases its own
  evidence.** The scale-up trigger was still not recorded, because the
  `cluster-autoscaler` container restarts shortly after each scale-up and
  recreates its status ConfigMap with `status: NoActivity` and a fresh
  `lastTransitionTime` — 13:31:54 for a node created at 13:28:41, and 12:42:23
  for one created at about 12:39:40 in the previous run. Polling the ConfigMap
  every 5s therefore never observes `InProgress`. The restart is proven
  independently: the autoscaler logs `lastScaleUpTime` with Go's monotonic
  offset, and upstream sets it to `time.Now().Add(-time.Hour)` at construction
  (`core/static_autoscaler.go:206` in 1.35.0), which puts one process start at
  12:42:12. Argo never marked the Application `OutOfSync`, so a re-apply is
  ruled out; a container restart in place leaves the Deployment Available, so
  Argo sees nothing. Capturing the pod's restart count, last termination reason
  and previous container log is the outstanding work, and it probably shares a
  cause with the control-plane restarts above.
