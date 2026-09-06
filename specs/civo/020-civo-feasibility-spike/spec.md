---
id: "CIVO-020"
title: "Civo feasibility spike on a throwaway cluster"
status: "READY"
priority: "P0"
milestone: "M0"
type: "research"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Procedural verification with a fixed checklist; findings matter more than design reasoning"
effort_estimate: "One session (3–4 h) plus cluster create/delete waits; cost under 2 USD"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-020 — Feasibility spike

## 1. Outcome and rationale

A written report in `specs/civo/research.md` (section "Spike results")
answering the questions that block CIVO-030 and CIVO-120, obtained from a
real, short-lived Civo cluster. Planning cannot settle them from
documentation.

## 2. Scope and non-goals

In scope: one Medium k3s cluster in LON1 created and destroyed by hand or
by throwaway Terraform in the scratch directory, never under
`terraform/live/`. Not in scope: any repository code, Argo, or AWS changes.

## 3. Current state / evidence

Unverified items from `research.md`: VolumeSnapshot support on
`csi.civo.com`; whether snapshots and volumes are account-level and survive
cluster deletion; cross-cluster volume re-attachment; exact default
application names; LB status IP vs hostname with and without reserved IP;
ServiceAccount OIDC discovery reachability; measured allocatable on Large.

## 4. Design and contracts

Checklist (each item records command, result, date):

1. Create cluster with `applications` set to remove Traefik and metrics-server; list `kubectl get pods -A` to confirm; record the exact names that worked.
2. `kubectl get sc,volumesnapshotclass`; attempt a `VolumeSnapshotClass` with driver `csi.civo.com` and a `VolumeSnapshot` of a 5 Gi PVC that has data; observe `readyToUse` and `civo volume` / API listing for a snapshot object.
3. Delete the cluster; `civo volume ls` and any snapshot listing; note what survived and its billing state.
4. Create a second cluster in the same network; try (a) `VolumeSnapshotContent` import by handle, (b) static PV with the retained volume ID; mount and verify data.
5. Deploy a `Service type=LoadBalancer` with and without `kubernetes.civo.com/ipv4-address` (reserved IP); record status `ip`/`hostname`, firewall behavior, deletion time.
6. Fetch `/.well-known/openid-configuration` and `/openid/v1/jwks` via the kubeconfig and anonymously; record.
7. `kubectl describe node` on a Large node: allocatable CPU/memory.
8. Note reserved IP and snapshot prices from the dashboard.
9. Destroy everything; confirm `civo` listings are empty; record total cost.

## 5. Files/components affected

- `specs/civo/research.md` (new section).
- `specs/civo/decisions.md` (persistence decision filled).
- `specs/civo/120-cnpg-on-civo-persistence/spec.md` (blocker cleared or redirected).
- No repository code.

## 6. Implementation steps

Run the checklist in order; write results as you go; destroy at the end
even on failure.

## 7. Dependencies and blockers

Needs the Civo API key on the workstation (`secrets/civo-token.enc` decrypt)
and the `civo` CLI. No spec dependencies.

## 8. Acceptance criteria

- Every checklist item has a recorded result or an explicit "could not test" with reason.
- The persistence decision in `decisions.md` is filled with option (a), (b), or (c) and evidence.
- Default application names for CIVO-030 are recorded.
- All spike resources deleted; cost recorded.

## 9. Validation

Real cloud, throwaway, under 2 USD. Cleanup: `civo kubernetes remove`,
`civo volume rm`, snapshot removal, network removal; verify with `civo ... ls`.

## 10. AWS regression protection

Not applicable; no AWS resources or repository code touched.

## 11. Rollout and rollback/recovery

None; results are documentation.

## 12. Risks and unresolved questions

- Snapshot objects may exist only in-cluster; then option (b) or (c) applies.
- Reserved-IP annotation may require the IP to be in the same network.

## 13. Definition of done

- [ ] Report merged into `research.md`
- [ ] `decisions.md` and CIVO-120 updated
- [ ] Spike resources gone; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT. Not run.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
