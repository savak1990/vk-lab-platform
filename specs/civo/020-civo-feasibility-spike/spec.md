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

The outcome is a written report in `specs/civo/research.md` (section "Spike results").
The report answers the questions that block CIVO-030 and CIVO-120.
We get the answers from a real, short-lived Civo cluster.
Planning cannot settle these questions from documentation.

## 2. Scope and non-goals

In scope: one Medium k3s cluster in LON1.
We create and destroy the cluster by hand, or with throwaway Terraform in the scratch directory.
We never put this Terraform under `terraform/live/`.
Not in scope: any repository code, Argo, or AWS changes.

## 3. Current state / evidence

The `research.md` file has these unverified items:

- VolumeSnapshot support on `csi.civo.com`.
- Whether snapshots and volumes are account-level and survive cluster deletion.
- Cross-cluster volume re-attachment.
- The exact default application names.
- The LB status IP vs hostname, with and without a reserved IP.
- ServiceAccount OIDC discovery reachability.
- The measured allocatable on a Large node.

## 4. Design and contracts

Checklist (for each item, record the command, the result, and the date):

1. Create the cluster with `applications` set to remove Traefik and metrics-server. Run `kubectl get pods -A` to confirm the result. Record the exact names that worked.
2. Run `kubectl get sc,volumesnapshotclass`. Create a `VolumeSnapshotClass` with driver `csi.civo.com`. Create a `VolumeSnapshot` of a 5 Gi PVC that has data. Observe `readyToUse`. Look for a snapshot object in `civo volume` and in the API listing.
3. Delete the cluster. Run `civo volume ls` and any snapshot listing. Record what survived and its billing state.
4. Create a second cluster in the same network. Try (a) a `VolumeSnapshotContent` import by handle. Try (b) a static PV with the retained volume ID. Mount the volume. Verify the data.
5. Deploy a `Service type=LoadBalancer` with and without `kubernetes.civo.com/ipv4-address` (reserved IP). Record the status `ip`/`hostname`, the firewall behavior, and the deletion time.
6. Fetch `/.well-known/openid-configuration` and `/openid/v1/jwks` through the kubeconfig and anonymously. Record the results.
7. Run `kubectl describe node` on a Large node. Record the allocatable CPU and memory.
8. Record the reserved IP price and the snapshot price from the dashboard.
9. Destroy everything. Confirm that the `civo` listings are empty. Record the total cost.

## 5. Files/components affected

- `specs/civo/research.md` (new section).
- `specs/civo/decisions.md` (persistence decision filled).
- `specs/civo/120-cnpg-on-civo-persistence/spec.md` (blocker cleared or redirected).
- No repository code.

## 6. Implementation steps

1. Run the checklist in order.
2. Write the results as you go.
3. Destroy all resources at the end, also on failure.

## 7. Dependencies and blockers

The spike needs the Civo API key on the workstation (decrypt `secrets/civo-token.enc`).
The spike needs the `civo` CLI.
The spike has no spec dependencies.

## 8. Acceptance criteria

- Every checklist item has a recorded result, or an explicit "could not test" with a reason.
- The persistence decision in `decisions.md` has option (a), (b), or (c), with evidence.
- The default application names for CIVO-030 are recorded.
- All spike resources are deleted. The cost is recorded.

## 9. Validation

The validation runs in the real cloud, on throwaway resources, for under 2 USD.
Cleanup steps:

1. Run `civo kubernetes remove`.
2. Run `civo volume rm`.
3. Remove the snapshots.
4. Remove the network.
5. Verify the cleanup with `civo ... ls`.

## 10. AWS regression protection

Not applicable. The spike touches no AWS resources and no repository code.

## 11. Rollout and rollback/recovery

None. The results are documentation.

## 12. Risks and unresolved questions

- Snapshot objects may exist only in the cluster. In that case, option (b) or (c) applies.
- The reserved-IP annotation may require the IP to be in the same network.

## 13. Definition of done

- [ ] Report merged into `research.md`
- [ ] `decisions.md` and CIVO-120 updated
- [ ] Spike resources gone; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT. Not run.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
