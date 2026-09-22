---
id: "HETZ-047"
title: "argo-down teardown ordering: the load balancer confirmed gone, and the CSI driver kept alive through the cascade"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One ordered teardown branch mirroring the Civo one; the risk is ordering, which the spike already measured"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-045", "HETZ-020"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-22"
completed: "2026-09-22"
---

# HETZ-047 — argo-down on Hetzner

## 1. Outcome and rationale

`argo-down` on hetzner deletes the `platform-gateway` Gateway and the
Envoy Service before the cascade starts, then blocks until `hcloud
load-balancer list` for the project returns `[]`. The hcloud cloud
controller manager (CCM) is a helm release outside Argo's ownership
(HETZ-045, decisions.md §3 "CCM before Argo") and never receives a
termination signal from the cascade; `cluster-down` destroys the servers
under whatever the CCM manages once `argo-down` returns. An LB whose
Service disappeared after its backing servers already died is orphaned
and keeps billing (HETZ-020 §4 item 3). This spec is the teardown half
HETZ-045 explicitly deferred to it.

## 2. Scope and non-goals

In scope: the hetzner branch of `scripts/argo-down.sh` and
`wait_for_lb_gone()` in `scripts/lib/provider.sh`. Also in scope: the
`depends_on`/`updated`/§14 edits this spec's existence triggers on
HETZ-140 and HETZ-150.

Not in scope: `argo-up` (HETZ-045, already written); the CCM install
itself and its helm release name `hccm` (HETZ-045); uninstalling the
CCM or Argo CD releases — `argo-down` never uninstalls either on any
provider, and `cluster-down` removes them by destroying
the servers they run on; `cluster-down`'s label-based sweep, which stays
the safety net for whatever this spec's wait times out on (HETZ-040);
the CSI volume/PVC teardown mechanics beyond relying on the existing
civo-only block widening to `!= aws` (HETZ-016) — this spec's own code
does not touch that guard.

## 3. Current state / evidence

- `scripts/argo-down.sh:32` guards on `cluster_exists`, already generic
  across providers; the hetzner arm of that guard arrives through
  HETZ-040, not as new code here. `:37` `configure_kubeconfig`; `:39-44`
  refuses to proceed if the cluster is unreachable; `:46-48` civo-only TLS
  export; `:57-80` disarms automated sync on every Application before
  anything destructive runs; `:82` `backup_teardown`; `:91-104`
  `TERMINATING_KINDS`, filtered on civo to kinds that actually exist;
  `:105-134` `report_remaining()`; `:136-137` HTTPRoute deletion;
  `:144-171` the Route 53 TXT-record wait (`ROOT_DOMAIN`/`FQDN`/`ZONE_ID`,
  unconditional on provider); `:180-204` the aws/civo wait on the
  Envoy-managed `LoadBalancer` Service in namespace `envoy`; `:230-247`
  the cascade (`kubectl delete application root --cascade=foreground`);
  `:249-273` the civo-only PVC/PV wait for `cnpg-system` and
  `observability`; `:281-288` the final `helm uninstall` of
  `root-application`/`argocd`, unconditional on provider and never naming
  the CCM.
- HETZ-020 §4 item 3 (spike checklist): a `type: LoadBalancer` Service
  carrying `use-private-ip`/`ipv6-disabled` annotations gets an hcloud LB
  from the CCM; deleting the Service deletes the LB; deleting every
  server while the Service (and its LB) still exist orphans the LB — the
  CCM has nothing left to react to once the servers are gone.
- HETZ-040's `cluster-down` sweep order is load balancers → volumes →
  servers not created by Terraform → primary IPs → firewalls, filtered by
  the `project=${PROJECT_NAME}` label, exit 1 on any leak — the net this
  spec's `wait_for_lb_gone()` is meant to make unnecessary in the normal
  case, not a mechanism this spec can rely on skipping.
- HETZ-045 §2: "Teardown for this target belongs to HETZ-047, not this
  spec … this spec no longer touches `scripts/argo-down.sh` at all."

## 4. Design and contracts

- `PROJECT_NAME`, used below as the `hcloud` label selector, is already
  exported by `scripts/lib/provider.sh` (HETZ-010); this spec adds no new
  input resolution.
- The steps ahead of the new block are unchanged and already generic:
  the `cluster_exists` existence proof (`:32`) and `configure_kubeconfig`
  (`:37`) — on hetzner `cluster_exists` true means a k3s cluster
  exists, which it does from the control plane's own boot (HETZ-030), not
  that `argo-up` ever ran; every step below therefore tolerates a cluster
  that holds no Argo CD, which is why the LB wait treats an already-absent
  Envoy Service as a no-op rather than an error; the unconditional `backup_teardown` gate (`:82`, generalised by
  HETZ-016/HETZ-120, best-effort because WAL archiving already made every
  committed row durable); disarming automated sync on every Application
  (`:57-80`) before anything destructive runs. The civo-only TLS export
  (`:46-48`) stays civo-only — hetzner's TLS Secret handling is HETZ-070's
  concern, not this spec's, and this branch adds none of its own.
- Hetzner branch, run where the aws/civo NLB wait sits today but placed
  before the Route 53 wait rather than after it: nothing about DNS
  record cleanup gates the LB, and the LB is the object still billing
  once its Service is gone, so it is removed first.
  - `kubectl delete gateway platform-gateway -n envoy --ignore-not-found`
    and `kubectl delete svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway --ignore-not-found`
    — both deleted explicitly rather than left to the generic cascade,
    because the cascade prunes one wave at a time and gives no guarantee
    the CCM observes the Service's deletion before Envoy Gateway's own
    controller Pod is itself pruned in a later wave.
  - `wait_for_lb_gone()` in `scripts/lib/provider.sh`: poll `hcloud
    load-balancer list -o json`, with **no label selector**, and match
    the names against `^${PROJECT_NAME}-`. Bounded by
    `HETZNER_LB_GONE_SECONDS` (default 180). On timeout, print the
    surviving names from the last poll and return 1; the caller exits 1
    — the same "surface, don't absorb" shape the DNS wait already uses.
  - **Corrected.** This bullet said `-l "project=${PROJECT_NAME}"`, and
    that selector cannot work. The cloud controller manager applies no
    labels to a load balancer it creates, which is exactly why HETZ-060
    gave `cluster-down`'s sweep its own unlabelled pass. A labelled poll
    returns `[]` on the first iteration whatever the true state, so the
    wait would have passed instantly and proved nothing — the same
    unfalsifiable shape §14 entry 5 caught twice before.
  - Do not route the poll through `hcloud_list_names`; that helper
    hardcodes `project=` into its selector.
  - A run where the Envoy Service is already gone (a retry, or a cluster
    that never got past `argo-up`) matches no name on the first poll — a
    no-op, not a special case.
- The Route 53 wait is unchanged in content and still unconditional on
  provider, but the load balancer block moves **above** it, for every
  provider rather than behind a hetzner branch. §14 entry 6 measured
  that wait clearing two records in under 10 s against a 180 s budget
  and concluded it "needs no change"; that measured the *frequency* of a
  timeout, not its *consequence*. The wait exits 1 on timeout, so an
  abort there leaves a billing load balancer with live servers and
  `cluster-down`'s sweep never runs. Route 53 cleanup and load balancer
  teardown are independent on every target, so one order serves all
  four and no second branch is introduced.
- **The CSI driver must outlive the cascade.** The PV wait runs after
  the cascade block, and the cascade's `kubectl delete --wait` returns
  only once every child Application is gone — `hcloud-csi` included. A
  PV with a `Delete` reclaim needs a live CSI controller, so no
  controller remains to perform it. Before the cascade, on hetzner
  only, strip the Argo finalizer from that Application:

  ```
  kubectl patch application hcloud-csi -n argocd --type=merge \
    -p '{"metadata":{"finalizers":null}}'
  ```

  Argo then deletes the Application object without pruning its
  resources, and the controller survives into the wait. The strip must
  run after the sync-disarm block, or a live `selfHeal` puts the
  finalizer back. Bring-up is untouched: the Application, its wave `-5`
  and its `StorageClass` all stay as they are.
- **Rejected: moving `hcloud-csi` out of Argo**, which §14 entry 6
  proposed as "the closer parallel" to the CCM. The CCM is an exception
  for a hard reason — the kubelet taints a new node
  `node.cloudprovider.kubernetes.io/uninitialized`, k3s CoreDNS does not
  tolerate that taint, and Argo CD needs cluster DNS to reach its own
  repository server, so Argo cannot install the controller that makes
  Argo's own DNS work. No such constraint applies to the CSI driver, and
  CLAUDE.md puts every Kubernetes controller under Argo CD. Moving one
  out to fix a teardown-only problem is the larger and the wronger
  change.
- The six load balancer messages naming "NLB", and the one naming
  `aws-load-balancer-controller`, become provider-neutral. §14 entry 6
  called this cheap to fix while touching that block.
- The cascade is unchanged.
- PVC and PV waits: the `!= aws` guard is HETZ-016's generalisation and
  is unchanged here, as is `ARGO_DOWN_PVC_WAIT_TIMEOUT` at 180s. Both
  waits stay warning-only. With a live CSI controller they now converge;
  if they do not, `cluster-down`'s sweep is still the net.
- `argo-down` never runs `helm uninstall hccm` (or `argocd`
  before the cascade finishes) — the final `helm uninstall` loop at
  `:281-288` names only `root-application` and `argocd`, unchanged by
  this spec. The CCM's helm release and its controller Pod stay running
  through the whole cascade and through the LB wait, which is what lets
  the LB be deleted from under a live controller instead of an
  already-dead one.

## 5. Files/components affected

`scripts/argo-down.sh` — the load balancer block moved above the
Route 53 wait, its AWS wording made provider-neutral, the
`wait_for_lb_gone` call added under a hetzner guard, and the
`hcloud-csi` finalizer strip added before the cascade.

`scripts/lib/provider.sh` — `wait_for_lb_gone()`.

No gitops file changes: the `hcloud-csi` Application, its wave and its
`StorageClass` are all untouched.

## 6. Implementation steps

1. Add `wait_for_lb_gone()` to `scripts/lib/provider.sh`, matching on
   the name prefix rather than a label selector.
2. Move the existing load balancer block above the Route 53 wait, make
   its wording provider-neutral, and call `wait_for_lb_gone` from it
   under a hetzner guard.
3. Add the `hcloud-csi` finalizer strip before the cascade.
4. **Test the finalizer assumption first.** During the cascade, watch
   `kubectl get deploy -n kube-system hcloud-csi-controller`. It must
   still be `Running` after `applications remaining: none`. If it is
   not, the run reverts to today's behavior and nothing is destroyed.
5. Confirm the PV wait now returns 0 instead of warning, and that
   `helm status hccm -n kube-system` stays `deployed` throughout.
6. Run `argo-down` again with the Service already deleted by hand;
   confirm the load balancer step no-ops.
7. Point `HETZNER_LB_GONE_SECONDS` at a value shorter than the real
   wait once, to prove the timeout path prints the surviving names and
   exits 1.
8. Run `PROVIDER=hetzner make full-down` end to end.

## 7. Dependencies and blockers

HETZ-045 supplies the CCM helm release and the reachable, `argo-up`'d
cluster this spec tears down. HETZ-020 supplies the LB-orphaning
evidence this design is built on. HETZ-016's widening of the PVC-wait
guard is not a listed dependency of this spec — it arrives transitively
the same way HETZ-045 describes its own transitive dependencies, and
this spec's own new code (the LB block) does not depend on it at all.

## 8. Acceptance criteria

- After `PROVIDER=hetzner make argo-down`, `hcloud load-balancer list`
  holds no name starting `$PROJECT_NAME-` before the cascade's first log
  line, with timestamps recorded in the run log. **Corrected**: this
  criterion selected on `-l project=$PROJECT_NAME` and was vacuously
  true, because the cloud controller manager labels nothing.
- `PROVIDER=hetzner make full-down` completes all four layers. §14
  entry 4 records "`make full-down` does not complete on this target,
  and cannot today"; that sentence becoming false is this spec's
  user-visible outcome, and this is the only criterion that tests the
  load balancer half and the CSI half together.
- The `hcloud-csi` controller Deployment is still `Running` after the
  cascade logs `applications remaining: none`.
- No PVC remains in `cnpg-system` or `observability` after the run, and
  the PV wait returns 0 rather than warning.
- `helm status hccm -n kube-system` reports `deployed` throughout the
  run and after it — `argo-down` never touches the CCM release.
- `PROVIDER=hetzner make cluster-down`, run immediately after, reports
  zero leaks in its sweep.
- A run with the Envoy Service already deleted before `argo-down` starts
  is a no-op for the LB step and still completes the cascade.

## 9. Validation

Offline: `shellcheck` against the HETZ-045 baseline, `bash -n`. Real
cloud: one hetzner `argo-down` run with the Service present, one with it
pre-deleted, and one forced timeout (`HETZNER_LB_GONE_SECONDS` set low),
all against a cluster already billed for HETZ-045's own validation.

## 10. AWS regression protection

The aws and civo branches of `scripts/argo-down.sh` are untouched — the
new block is a hetzner-only branch, additive at the point the aws/civo
NLB wait already occupies. Record one aws `argo-down`/`argo-up` cycle
and one civo cycle, diffed as redacted `set -x` traces against the
pre-change traces, the same evidence shape HETZ-045 §10 uses.

## 11. Rollout and rollback/recovery

Revert the script and the lib function. If a run leaves an LB orphaned
because of a bug in the new block, `cluster-down`'s sweep (HETZ-040)
still deletes it and fails the run — the existing safety net, not a new
risk this spec introduces. No data risk: this spec adds no new write
path to persistent state.

## 12. Risks and unresolved questions

- If automated sync is not disarmed before the Gateway/Service delete,
  Argo CD recreates the Envoy Service on its next reconcile; the
  existing disarm loop (`:57-80`) runs before this block in script order,
  a placement invariant to preserve, not a new mechanism.
- `wait_for_lb_gone()`'s poll interval and the CCM's own deletion
  latency are independent; `HETZNER_LB_GONE_SECONDS` default 180 is a
  guess pending one real timing from the HETZ-045 cluster, not a
  measured bound.
- A PVC stuck in `cnpg-system`/`observability` past its wait leaves its
  volume attached, which then blocks `cluster-down`'s server deletion;
  the sweep detaches before deleting, so a stuck PVC here surfaces as a
  slower `cluster-down`, not a failed one.
- Deleting the Hetzner API token in the console while the CCM is still
  running — which this spec's design deliberately keeps true for longer
  than an already-dead controller would need — breaks the running
  cluster; already recorded in HETZ-045 §12 and ADR 0030's amendment,
  repeated here because this spec's whole design leans on the CCM
  staying alive through the wait.

## 13. Definition of done

- [ ] Acceptance criteria evidence recorded for hetzner
- [ ] `shellcheck` shows no new warnings
- [ ] AWS and Civo `argo-down`/`argo-up` traces recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); takes the `argo-down`
  part of the old HETZ-045.
- 2026-09-20 — review fix: §4 states what `cluster_exists` true does and
  does not prove on hetzner, and that the Argo guard tolerates a cluster
  with no Argo CD in it.
- 2026-09-20 — k3s (HETZ-017, ADR 0037): wording only. `cluster_exists`
  proves a k3s cluster, there is no Cilium release for `argo-down` to leave
  alone, and the spike's load-balancer item renumbered from 4 to 3. The
  LB-before-cascade ordering, the `wait_for_lb_gone` contract and the PVC
  wait are unaffected — they are CCM-level and bootstrap-agnostic.
- 2026-09-22 — measured on the first full Hetzner teardown (HETZ-045's live
  cycle, three `cx33` in `fsn1`), and it gives this spec a second, larger job
  than the load-balancer ordering it was written for.

  **`make full-down` does not complete on this target, and cannot today.**
  `argo-down` deletes the PVCs, then waits `ARGO_DOWN_PVC_WAIT_TIMEOUT`
  (default `180s`) for each PV to go. The hcloud CSI driver needs longer than
  that to detach and delete the volume behind a PV, so the wait timed out three
  times in one run. `argo-down` warns and continues, as designed.
  `cluster-down` then finds the volume that outlived the cluster, deletes it,
  and exits 2 - which is correct and deliberate, "a bug to fix, not a condition
  to silence". But `make` stops a chained target on a non-zero exit, so
  `persistent-down` and `bootstrap-down` never ran. The Route 53 zone, the
  backups bucket, the hcloud network and the SSH key were all still up
  afterwards, and had to be destroyed by hand.

  Two separate problems, and the second is the one that matters:
  1. The 180 s budget is too short for this CSI. It is already tunable by
     environment variable, so the fix is a number, not code. Measure the real
     detach-and-delete time before choosing it rather than doubling blindly.
  2. Even with a correct budget, any leak at all stops `full-down` two layers
     early. That is the designed behaviour of the sweep and must not be
     softened. What it means is that `full-down` is not a one-shot on a target
     whose volumes are deleted asynchronously, and either the ordering or the
     operator documentation has to say so. `README.md` now does.

  Timing from the same run, for whoever sizes the budgets: cold `make full-up`
  12m50s, `full-down` 14m14s before it halted, and 6m01s more for the two
  abandoned layers.

- 2026-09-22 — HETZ-060 makes this spec's premise live. Until it merged, this
  target rendered no Gateway and no Envoy Service, so `argo-down`'s existing
  provider-generic block (`:238-266`, which selects on
  `spec.type == LoadBalancer` in namespace `envoy`) always took its else
  branch and printed "nothing to wait on". Three of this spec's five
  acceptance criteria were unfalsifiable in that state: 1 and 5 pass trivially
  against a project that can hold no load balancer, and 4 was failing for the
  PVC-budget reason above rather than for any load-balancer reason. The first
  HETZ-060 live cycle is therefore this spec's first real evidence, and what
  it adds on top is a stronger assertion — `wait_for_lb_gone()` raises the
  check from "the Service object is gone" to "`hcloud load-balancer list` is
  empty", closing the window in which the Service disappears before the
  Hetzner API has finished.

  One failure this spec does not cover, recorded so it is not mistaken for
  covered: `argo-down`'s Route 53 record wait (`:203-237`) runs *before* the
  Envoy Service deletion and exits 1 on timeout. It was inert while no
  ExternalDNS record existed on this target; HETZ-060 makes it load-bearing.
  An abort there leaves a load balancer whose servers are still running, and
  `cluster-down`'s sweep — including the name-prefix pass HETZ-060 adds — never
  runs at all, because `make` stops the chain. Measure that wait on the first
  HETZ-060 cycle before deciding whether it needs reordering.

- 2026-09-22 — **the PVC-budget entry above is wrong about the cause, and the
  second teardown proves it.** That entry concluded "the fix is a number, not
  code - measure the real detach-and-delete time". The measurement says
  otherwise: no number works.

  What the run showed, in order, from `argo-down`'s own log:

  ```
  applications remaining: cnpg-operator, envoy-gateway, external-secrets, hcloud-csi, root
  applications remaining: none          <- the cascade deleted hcloud-csi here
  cascade complete.
  waiting for PV pvc-15b81032-... (backing volume) to finish deleting...
  error: timed out waiting for the condition ... 180s
  ```

  The cascade removes the `hcloud-csi` Application, and only then does the PV
  wait begin. A PV with a `Delete` reclaim needs a live CSI controller to do
  the deleting, so by the time the wait starts there is nobody left to
  perform it. `argo-down` spent six minutes waiting for an event that could
  not occur.

  Measured directly against the Hetzner API rather than inferred: both volumes
  were **detached** within the wait and stayed present, unchanged, for over
  four minutes. They disappeared at 14:25:22Z, four seconds after
  `cluster-down` ran `hcloud volume delete` on them at 14:25:18Z. Nothing
  else deleted them, and nothing else was going to.

  `research.md` recorded this same trap from the feasibility spike - "the
  PV's `Delete` reclaim needs a live CSI controller" - and the note was read
  as being about server deletion rather than about the Argo cascade.

  So this spec's work changes shape. Raising `ARGO_DOWN_PVC_WAIT_TIMEOUT`
  buys nothing; the ordering has to change, so that either the PVCs are
  deleted and their volumes confirmed gone **before** the cascade prunes
  `hcloud-csi`, or that Application is excluded from the cascade the way the
  CCM release already is (HETZ-045, decisions.md §3). The second is the
  closer parallel: the CSI driver is in the same class as the cloud
  controller manager - a controller whose own resources outlive the objects
  that Argo owns.

  Until then the sweep is the safety net and behaves correctly: it deleted
  the surviving volume and exited non-zero so the condition surfaced.

  Two smaller items from the same run. `argo-down`'s Route 53 record wait
  (`:203-237`), newly load-bearing now that HETZ-060 lets external-dns
  publish, cleared two records in under 10 s against its 180 s budget and
  needs no change. And the load balancer block's messages name "NLB" and
  "aws-load-balancer-controller", which read wrongly on a Hetzner teardown -
  cosmetic, and cheap to fix when this spec touches that block.

  For the record, this spec's own premise is now exercised: `argo-down`
  deleted the Gateway, the Service went within one poll, and the hcloud load
  balancer was gone **1 s** later, with nothing left for the sweep. The
  window `wait_for_lb_gone()` closes is therefore small in the happy case -
  its value is the slow case, which this run did not produce.

- 2026-09-22 — implemented. The shape the two entries above arrived at is
  what shipped, with one further correction and one rejection.

  **A fifth false claim, found before any code was written.** §4 and §8
  criterion 1 both polled `hcloud load-balancer list -l
  "project=${PROJECT_NAME}"`. The cloud controller manager applies no labels
  to what it creates — the finding that made HETZ-060 add an unlabelled
  name-prefix pass to `cluster-down`'s sweep. That selector returns `[]` on
  the first iteration whatever the true state, so `wait_for_lb_gone()` as
  specced would have passed instantly and proved nothing, and the criterion
  measuring it was vacuously true. Both now match `^${PROJECT_NAME}-`. This
  is the third unfalsifiable criterion this spec has produced; the first two
  are in entry 5.

  **Entry 6's prescription was rejected, and the reason is architectural.**
  That entry proposed installing `hcloud-csi` as a helm release, "the way
  the CCM release already is — the second is the closer parallel". The
  parallel does not hold. The CCM sits outside Argo because of a hard
  ordering constraint: the kubelet taints a new node
  `node.cloudprovider.kubernetes.io/uninitialized`, k3s CoreDNS does not
  tolerate that taint, and Argo CD needs cluster DNS to reach its own
  repository server — so Argo cannot install the controller that makes
  Argo's own DNS work. Nothing equivalent constrains the CSI driver, and
  CLAUDE.md puts every Kubernetes controller under Argo CD. What shipped
  instead strips the Argo finalizer from the `hcloud-csi` Application before
  the cascade, so Argo deletes that object without pruning its resources and
  the controller survives into the PV wait. Teardown behavior changes;
  bring-up does not change at all.

  **The Route 53 position was decided rather than inherited.** Entry 6 said
  that wait "needs no change", having measured it clear two records in under
  10 s against a 180 s budget. That measured how often it times out, not
  what a timeout costs. It exits 1, and it ran before the load balancer
  teardown, so an abort there left a billing load balancer with live servers
  and no sweep. The block moved above it — for every provider, not behind a
  hetzner branch, because the two cleanups are independent everywhere and
  one teardown order across four targets is worth more than a saved test.

  Six messages in that block said "NLB" and one named
  `aws-load-balancer-controller`, which on this target is `hccm`. All are now
  provider-neutral, as entry 6 suggested while the block was open.
  `ARGO_DOWN_NLB_TIMEOUT` became `ARGO_DOWN_LB_TIMEOUT`; nothing outside the
  script referenced the old name.

  Offline: `shellcheck` clean (one pre-existing SC1091 on a sourced path),
  `bash -n`, all four script tests, and `make gitops-check` unchanged — no
  gitops file was touched.

  **Outstanding, and it is the central one.** Every acceptance criterion
  that needs a cluster is unmet until the live cycle runs. The load balancer
  half is low risk; the finalizer strip is not, because it rests on Argo
  deleting a finalizer-less Application without pruning its resources. That
  reading is corroborated by the codebase already stripping finalizers to
  change Application deletion behavior, but it is not proven. If it is
  wrong, the CSI driver is pruned exactly as it is today, the run log says
  so, and nothing is destroyed. Watch
  `kubectl get deploy -n kube-system hcloud-csi-controller` across
  `applications remaining: none` first, before anything else in the cycle.
