---
id: "CIVO-020"
title: "Civo feasibility spike on a throwaway cluster"
status: "DONE"
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
updated: "2026-09-07"
completed: "2026-09-07"
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

The `research.md` file had these unverified items. Status after the 2026-09-07 run:

- VolumeSnapshot support on `csi.civo.com` — settled from driver source before the run; not supported.
- Whether volumes are account-level and survive cluster deletion — VERIFIED, they survive and keep billing.
- Cross-cluster volume re-attachment — NOT TESTED; still open as a bounded experiment.
- The exact default application names — VERIFIED, and `-metrics-server` proved inert.
- The LB status IP vs hostname, with and without a reserved IP — VERIFIED, both fields are present.
- ServiceAccount OIDC discovery reachability — VERIFIED as unreachable; federation is impossible.
- The measured allocatable on a node — MEASURED at 2308 MiB. The spike measured a **Medium**
  node, not a Large node as this section first said. The pool decision is three Medium nodes.
  The downstream specs therefore need the Medium figure.

## 4. Design and contracts

Checklist (for each item, record the command, the result, and the date):

1. Create the cluster with `applications` set to remove Traefik and metrics-server. Run `kubectl get pods -A` to confirm the result. Record the exact names that worked.
2. Run `kubectl get sc,volumesnapshotclass`. Create a `VolumeSnapshotClass` with driver `csi.civo.com`. Create a `VolumeSnapshot` of a 5 Gi PVC that has data. Observe `readyToUse`. Look for a snapshot object in `civo volume` and in the API listing.
3. Delete the cluster. Run `civo volume ls` and any snapshot listing. Record what survived and its billing state.
4. Create a second cluster in the same network. Try (a) a `VolumeSnapshotContent` import by handle. Try (b) a static PV with the retained volume ID. Mount the volume. Verify the data.
5. Deploy a `Service type=LoadBalancer` with and without `kubernetes.civo.com/ipv4-address` (reserved IP). Record the status `ip`/`hostname`, the firewall behavior, and the deletion time.
6. Fetch `/.well-known/openid-configuration` and `/openid/v1/jwks` through the kubeconfig and anonymously. Record the results.
7. Run `kubectl describe node`. Record the allocatable CPU and memory. (Changed at run time: the spike measured a **Medium** node, not the Large node written here. The pool decision is three Medium nodes.)
8. Record the reserved IP price and the snapshot price from the dashboard.
9. Destroy everything. Confirm that the `civo` listings are empty. Record the total cost.

**Review amendments (2026-09-06, kubernetes-architect):**
- Drop item 4(a) (`VolumeSnapshotContent` import) and the `VolumeSnapshotClass` part of item 2. The `csi.civo.com` driver source lists no snapshot capability, so the question is settled without a cluster.
- Item 4(b) (static PV rebind of a retained volume) stays as an optional experiment. The result informs no M1 spec.
- Add: record the Civo Object Store price and minimum size in the dashboard, and the exact strings shown by `civo kubernetes applications ls` for the default apps (expected `traefik2-nodeport` and `metrics-server`).

## 5. Files/components affected

- `specs/civo/research.md` (new "Spike results" section; five stale rows corrected).
- `specs/civo/decisions.md` (default-app-names row decided; ADR 0013 note and reserved-IP row corrected).
- `specs/civo/030-civo-terraform-cluster/spec.md` (app string, k3s version, memory figure, two acceptance criteria).
- `specs/civo/README.md` (index).
- No repository code.

This spike does not edit CIVO-120. The review of 2026-09-06 already removed the CIVO-020
blocker from CIVO-120. That same review pointed its dependencies at CIVO-180.

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
- `decisions.md` records the persistence decision with evidence. The review of 2026-09-06 already
  made that decision: option (d), logical dumps to S3. It made the decision after the CSI driver
  source settled that option (a) is impossible. The spike supplies evidence, not the choice.
- The default application names for CIVO-030 are recorded.
- All spike resources are deleted. The cost is recorded.

## 9. Validation

The validation runs in the real cloud, on throwaway resources, for under 2 USD.
Cleanup steps:

1. Run `civo kubernetes remove`.
2. Run `civo volume delete`.
3. Run `civo ip delete` for the reserved IP.
4. Remove every firewall. **One cluster and one LoadBalancer produced four firewalls. Civo
   created three of them. The spike requested only one.** A sweep that expects one firewall per
   cluster leaves the other three behind.
5. Remove the network. It deletes only once empty.
6. Verify the cleanup with `civo ... ls` across every resource type: `kubernetes`, `loadbalancer`,
   `volume`, `ip`, `instance`, `network`, `firewall`.

There are no snapshots to remove; `csi.civo.com` cannot create them.

## 10. AWS regression protection

Not applicable. The spike touches no AWS resources and no repository code.

## 11. Rollout and rollback/recovery

None. The results are documentation.

## 12. Risks and unresolved questions

- ~~Snapshot objects may exist only in the cluster.~~ Settled: the driver advertises no snapshot
  capability and the cluster carries no snapshot CRDs at all.
- ~~The reserved-IP annotation may require the IP to be in the same network.~~ Settled: the
  annotation worked against an IP reserved before the network existed. Reserved IPs are
  region-scoped, not network-scoped.
- Still open: does a retained volume keep its filesystem and its data when a new cluster binds it
  by `volumeHandle`? The spike measured that the volume object survives. The spike did not read
  the data back.

## 13. Definition of done

- [x] Report merged into `research.md`
- [x] `decisions.md` updated (CIVO-120 needed no change; see section 5)
- [x] Spike resources gone, verified by empty `civo ... ls` across every resource type
- [x] Index updated
- [x] Change on `main` (no pull request); status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT. Not run.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
- 2026-09-07 — the spike ran against a real LON1 cluster. The spec moved to IN_PROGRESS.
  This status change happened after the run. The protocol requires it before the run.
  Environment: `civo` CLI v1.5.4, Terraform 1.15.9, provider `civo/civo` v1.3.2, one
  `g4s.kube.medium` node, k3s `1.35.0-k3s1`. Throwaway Terraform created the cluster and the
  network. That Terraform stayed in a scratch directory outside the repository. It never went
  under `terraform/live/`.
  Civo billed four line items at one hour each: the node, the load balancer, a 1 GB volume, and
  the reserved IP. The total was about 0.05 USD, plus one hour of reserved IP at a price Civo
  does not publish. The ceiling was 2 USD.
  The spike deleted every resource. The leak check found nothing.
- 2026-09-07 — the spike changed the checklist. This entry records each change.
  The `civo-csi` driver source already settled items 2, 3 and 4(a). The spike did not run them.
  The spike skipped item 4(b), the static PV rebind. The amendment says it informs no M1 spec.
  The spike did measure that the volume object survives cluster deletion. The spike did not test
  the data on that volume after a rebind. That test stays open.
  Earlier research already settled the snapshot price and the object-store price in item 8. The
  spike did not fetch them again.
  The spike could not get the reserved-IP price. Civo bills the IP as its own `reserved-ip` line
  item. The charges API reports hours, never money. The paths `/v2/pricing`, `/v2/prices`,
  `/v2/billing/pricing` and `/v2/account/pricing` all return 404.
  The API route failed, so the search moved to Civo's published documents. No Civo public-cloud
  page states a price. The only Civo figure for an IP is £2.25 per IP in the G-Cloud 14
  enterprise listing. That listing states no billing period, so the figure is not usable.
  Civo does state two related facts. First: "Public IPs beyond the cluster IP are charged
  separately." Second: charging stops when you delete the IP, not when you detach it.
  This spec records the price as "could not test". Read the rate from a dashboard invoice.
  This evidence produced two decisions. `decisions.md` records both. First: the Civo network
  stays dedicated, because the spike measured a network as free. Second: the platform keeps the
  reserved IP for M1 and reviews the choice again after CIVO-110.
  The spike added four questions, because no Civo document answers them:
  (a) Does a LoadBalancer survive cluster deletion? It does not. Civo deletes it server-side.
  (b) Does a CSI volume survive cluster deletion? It does, and it keeps billing.
  (c) Is the algorithm value `round_robin` or `round-robin`? It is `round_robin`.
  (d) Is `g4s.kube.large` selectable in LON1? It is.
- 2026-09-07 — the report, the corrected rows, and the two decisions landed on `main` in commit
  `e83d1f4`. No pull request was opened. The operator set the default to push straight to `main`,
  and `specs/civo/README.md` now records that. Promoted to `DONE`.
  CIVO-030 is the only direct dependent. Its `blocked_by` is empty and needs no change.
