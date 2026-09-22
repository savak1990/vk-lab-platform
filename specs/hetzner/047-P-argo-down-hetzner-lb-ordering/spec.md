---
id: "HETZ-047"
title: "argo-down Hetzner branch: Envoy Service and LB removed before the cascade; CCM release never uninstalled"
status: "READY"
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
updated: "2026-09-20"
completed: ""
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
    load-balancer list -l "project=${PROJECT_NAME}" -o json` every
    `$POLL_INTERVAL` until the result is `[]`, bounded by
    `HETZNER_LB_GONE_SECONDS` (default 180). On timeout, print the
    surviving LB names from the last poll and exit 1 — the same
    "surface, don't absorb" shape the DNS and NLB waits already use.
  - A run where the Envoy Service is already gone (a retry, or a cluster
    that never got past `argo-up`) sees `hcloud load-balancer list`
    return `[]` on the first poll — a no-op, not a special case.
- The Route 53 wait (`:144-171`) is unchanged and unconditional on
  provider; it runs after the hetzner block above, in its existing
  position. The cascade (`:230-247`) is unchanged.
- PVC wait (`:249-273`): its `[ "$PROVIDER" = civo ]` guard widening to
  `!= aws` is HETZ-016's generalisation, not new work here; this spec
  relies on that guard existing by the time this branch runs and adds no
  code of its own to it.
- `argo-down` never runs `helm uninstall hccm` (or `argocd`
  before the cascade finishes) — the final `helm uninstall` loop at
  `:281-288` names only `root-application` and `argocd`, unchanged by
  this spec. The CCM's helm release and its controller Pod stay running
  through the whole cascade and through the LB wait, which is what lets
  the LB be deleted from under a live controller instead of an
  already-dead one.

## 5. Files/components affected

`scripts/argo-down.sh`, `scripts/lib/provider.sh` (`wait_for_lb_gone`).

## 6. Implementation steps

1. Add `wait_for_lb_gone()` to `scripts/lib/provider.sh`.
2. Add the hetzner branch to `scripts/argo-down.sh`: Gateway + Service
   delete, then `wait_for_lb_gone`, placed before the existing Route 53
   wait.
3. Run `PROVIDER=hetzner make argo-down` against the HETZ-045 baseline
   with the Envoy Service present; confirm `hcloud load-balancer list`
   is empty before the cascade's log line and `helm status hccm -n
   kube-system` stays `deployed` throughout.
4. Run it again with the Service already deleted by hand; confirm the LB
   step no-ops.
5. Point `HETZNER_LB_GONE_SECONDS` at a value shorter than the real wait
   once, to prove the timeout path prints the surviving LB names and
   exits 1.

## 7. Dependencies and blockers

HETZ-045 supplies the CCM helm release and the reachable, `argo-up`'d
cluster this spec tears down. HETZ-020 supplies the LB-orphaning
evidence this design is built on. HETZ-016's widening of the PVC-wait
guard is not a listed dependency of this spec — it arrives transitively
the same way HETZ-045 describes its own transitive dependencies, and
this spec's own new code (the LB block) does not depend on it at all.

## 8. Acceptance criteria

- After `PROVIDER=hetzner make argo-down`, `hcloud load-balancer list -l
  project=$PROJECT_NAME` is `[]` before the cascade's first log line,
  with timestamps recorded in the run log.
- No PVC remains in `cnpg-system` or `observability` after the run.
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
