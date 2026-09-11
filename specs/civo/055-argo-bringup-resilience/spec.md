---
id: "CIVO-055"
title: "Reliable bring-up and teardown: fail fast on CRDs that never establish"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "The diagnosis is already done and recorded below; the work is a guard in one script plus its acceptance evidence"
effort_estimate: "One session (3–5 h) including one induced-failure test and one clean cycle"
estimate_confidence: "medium"
depends_on: ["CIVO-045"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# CIVO-055 — Reliable bring-up: fail fast on CRDs that never establish

## 1. Outcome and rationale

`PROVIDER=civo make up` either succeeds or fails with an actionable message
naming the broken resource, within about two minutes of the fault being
observable. It never spends its full 2700-second watch on a fault that was
visible from the API server minutes in.

The driver is a real failure observed on 2026-09-11 during CIVO-115's
verification. A k3s control-plane fault left fourteen CustomResourceDefinitions
created but never *established*, and nothing in the platform noticed for
forty-five minutes. Argo reported the owning Application `Synced`, because the
CRD objects existed; the API server refused to serve those resource types,
because their status was never written. The operator saw a bring-up that simply
hung.

A lab whose `make up` can hang for forty-five minutes without saying why is not
a lab anyone wants to start and stop several times a day.

## 2. Scope and non-goals

In scope:
- A CRD-establishment guard inside `scripts/argo-up.sh`'s existing watch loop:
  detect CRDs whose `Established` condition is not `True` after a dwell time,
  and name them.
- An opt-out self-heal: delete those CRDs so Argo's `selfHeal` recreates them,
  bounded to one attempt per bring-up.
- One induced-failure test proving the guard fires and reports correctly.

Not in scope:
- Splitting the envoy-gateway chart's CRDs into their own Application. That is
  a plausible mitigation (§12) but unproven, and it changes the GitOps tree
  rather than the failure reporting. Reassess once this spec's evidence says
  whether the fault recurs.
- The AWS target's equivalent work, which `specs/032-argo-bootstrap-resilience`
  already proposes. The guard added here is target-agnostic and runs on both,
  but only civo is verified in this spec.
- Any change to `ARGO_UP_WATCH_SECONDS`, Argo's retry budget, or ADR 0025's
  retry-over-readiness-gates decision. This spec adds a detector, not a gate.
- Teardown reliability. `scripts/argo-down.sh` and `scripts/cluster-down.sh`
  already fail closed and sweep leaks; no fault was observed there. If teardown
  reliability work is wanted it belongs in its own spec.

## 3. Current state / evidence

Recorded 2026-09-11 on `vk-civo-lab`, k3s `v1.35.0+k3s1`, during CIVO-115's
real-cloud verification:

- Twenty-odd CRDs were applied in one batch at `15:57:37Z`. Four established.
  The remaining fourteen — every `gateway.networking.k8s.io` and
  `gateway.envoyproxy.io` kind — did not. Fifty-four other CRDs in the same
  cluster, including cert-manager's own, CNPG's and External Secrets', were
  fine.
- The stuck objects were valid: `spec.names`, `spec.group`, `spec.scope` and
  two schema-bearing versions all present. Only their status was missing —
  `status.acceptedNames` empty, no `Established` and no `NamesAccepted`
  condition. The API server's naming controller never ran on them.
- `kubectl get httproutes -A` returned `the server doesn't have a resource
  type "httproutes"`.
- Downstream: cert-manager v1.21.1 exits at startup with `the Gateway API CRDs
  do not seem to be present, but ExperimentalGatewayAPISupport is set to true`
  — that feature gate is a chart default, not something this repository sets.
  It reached `CrashLoopBackOff` on a 5-minute backoff. With cert-manager down,
  the `eso-ra-cert` and `external-dns-ra-cert` Secrets were never issued, so
  external-secrets and external-dns sat in `ContainerCreating` indefinitely.
- Annotating a stuck CRD to force a reconcile had no effect.
- `scripts/argo-up.sh:476-505` already exits early on a *failed sync
  operation*, but a wedged CRD produces no failed operation: Argo's sync
  succeeded. The loop therefore falls through to the `WATCH_SECONDS` timeout at
  line 506, whose message names only the pending resources, not the cause.

**ADR 0025 does not cover this case.** Its remedy for a late-arriving CRD is
`syncPolicy.retry`, which works when a resource is *missing*. Here the resource
exists and Argo considers it applied, so no retry is ever attempted. This is a
genuine gap in that decision, not a misapplication of it.

## 4. Design and contracts

- The guard runs inside the existing watch loop in `scripts/argo-up.sh`,
  beside the current failed-operation check, so it costs no new polling
  machinery.
- It lists CRDs whose `Established` condition is not `True`. A CRD is briefly
  not-established immediately after creation, so a CRD must stay that way for
  `ARGO_UP_CRD_DWELL_SECONDS` (default `90`) before the guard treats it as
  stuck.
- On detection the guard prints every stuck CRD by name, plus the one-line
  explanation that the API server is not serving those kinds, and what that
  blocks.
- **Self-heal, default on, disabled with `ARGO_UP_CRD_SELF_HEAL=0`:** delete
  the stuck CRDs and let Argo's `selfHeal` recreate them. One attempt per
  bring-up; if they are still stuck after a second dwell, exit non-zero with
  the same named list.
- **The invariant that makes deletion safe, and the reason this is not
  reckless:** a CRD that never established cannot have any custom resources,
  because the API server never served that resource type. Deleting it can
  destroy nothing. This is *not* true of an established CRD, where deletion
  cascades to every object of that kind — so the guard must key strictly on
  `Established != True` and must never touch an established CRD.
- Exit code on unrecoverable detection is non-zero, matching the script's
  existing failure convention, so `make up` fails loudly rather than hanging.

## 5. Files/components affected

`scripts/argo-up.sh` (the watch loop at lines 471-511, and a new helper beside
`print_app_status`/`pending_resources`/`operation_state` at lines 436-465).
No GitOps template, no Terraform, no ADR.

## 6. Implementation steps

1. Add a helper that emits the names of CRDs whose `Established` condition is
   not `True`, one per line, empty when all are healthy.
2. Track how long that set has been non-empty inside the watch loop; act only
   past the dwell threshold.
3. On first detection, print the named list and the consequence.
4. If self-heal is enabled, delete exactly those CRDs, log each deletion, and
   reset the dwell timer once.
5. If the same set is still stuck after the second dwell, print it and exit
   non-zero.
6. Induce the failure to prove the guard fires — see §9.
7. Run one clean `PROVIDER=civo make up` and confirm the guard stays silent and
   adds no measurable time.

## 7. Dependencies and blockers

CIVO-045 supplies the `argo-up`/`argo-down` civo branches this modifies.
Nothing blocks it.

## 8. Acceptance criteria

- With a deliberately un-establishable CRD present, `make up` names it and
  exits non-zero within roughly two minutes of the dwell threshold, instead of
  running to the 2700-second timeout.
- With self-heal enabled and a genuinely transient fault, the bring-up recovers
  without operator intervention and says what it did.
- With `ARGO_UP_CRD_SELF_HEAL=0`, nothing is deleted and the guard only reports.
- The guard never deletes a CRD whose `Established` condition is `True`. State
  this as a test, not an intention.
- A healthy `PROVIDER=civo make up` is unaffected: the guard prints nothing and
  the run's duration is unchanged within noise.
- The AWS path is unchanged — `make -n up` output for `PROVIDER=aws` is
  identical to before, and the guard is verified not to fire on a healthy AWS
  cluster or is explicitly recorded as untested there.

## 9. Validation

Offline: `shellcheck scripts/argo-up.sh`, `bash -n scripts/argo-up.sh`.

Induced failure, cheapest known method: apply a CRD carrying an
`api-approved.kubernetes.io` annotation pointing at an unapproved URL for a
`*.k8s.io` group, which the API server refuses to establish while leaving the
object in place — the same observable state as the real fault. Confirm the
guard names it, then confirm self-heal deletes it and the run proceeds.

Real cloud: one `PROVIDER=civo make up` / `make down` cycle, under 1 USD. No
Let's Encrypt production order is spent — `civo_export_tls_secret` and
`civo_import_tls_secret` round-trip the existing certificate through SSM.

## 10. AWS regression protection

No GitOps template changes, so the golden render is untouched by construction;
run `scripts/gitops-render-check.sh` anyway to prove it. `scripts/argo-up.sh`
is shared by both targets, so the guard must be written target-agnostically and
the AWS branch of the script must be re-read for ordering assumptions before
merge.

## 11. Rollout and rollback/recovery

Data risk: none. The guard only ever deletes CRDs that the API server is not
serving, which by the §4 invariant can own no objects. Rollback is reverting
the commit; the platform returns to its current behaviour of timing out
silently. Setting `ARGO_UP_CRD_SELF_HEAL=0` disables the destructive half
without a code change.

## 12. Risks and unresolved questions

- **Whether the fault recurs is unknown.** It was seen once, on one cluster, on
  k3s `v1.35.0+k3s1`. If a second occurrence is observed, record the k3s version
  alongside it — a version-correlated pattern would point at a k3s regression
  worth reporting upstream, and would also justify the batch-splitting
  mitigation below.
- Splitting the envoy-gateway CRDs into a dedicated Application (the pattern
  `gitops/templates/platform/aws/ebs-csi/snapshot-controller.yaml` already uses
  for `external-snapshotter-crds`) would shrink the batch that wedged. It is
  deferred because the causal link between batch size and the wedge is
  unproven, and because it would change the GitOps tree rather than the
  reporting this spec is about.
- Self-heal could in principle mask a genuine, repeating fault by papering over
  it each run. The log line it prints on every deletion is the mitigation:
  a bring-up that self-heals is not a silent bring-up.
- The dwell default of 90 seconds is a guess informed by one observation, where
  the fault was already apparent within seconds of the batch landing. Measure
  on the first clean run and adjust.

## 13. Definition of done

- [ ] Guard implemented, with the induced-failure test and the clean-run
      evidence both recorded
- [ ] Self-heal proven to recover, and proven not to touch established CRDs
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as READY. Diagnosis captured live during CIVO-115's
  real-cloud verification: fourteen envoy-gateway CRDs created but never
  established on k3s `v1.35.0+k3s1`, silently hanging `make up` for
  forty-five minutes. The operator asked for a reliable start/stop cycle as
  the outcome; this spec is scoped to making the failure loud and, where it
  is transient, self-correcting.
