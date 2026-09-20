---
id: "HETZ-020"
title: "Feasibility spike: k3s and the hcloud CCM, CSI and load balancer on throwaway cx33 servers, with a written report"
status: "IN_REVIEW"
priority: "P0"
milestone: "M0"
type: "research"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Procedural verification with a fixed checklist; findings matter more than design reasoning"
effort_estimate: "Half a session (2–3 h) plus boot waits and one invoice read; cost under 1 EUR"
estimate_confidence: "medium"
depends_on: ["HETZ-017"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-20"
completed: ""
---

# HETZ-020 — Feasibility spike

## 1. Outcome and rationale

The outcome is a written report in `specs/hetzner/research.md` (new "Spike
results" section). Most of what the 2026-09-11 spike plan asked for is
already answered: real `hcloud`/Terraform create and delete on `cx33`,
stock across `nbg1`/`fsn1`/`hel1`, the API price list, and every pinned
tool version were proven on 2026-09-19 and recorded in `research.md` (rows
"Cheap lines are stock-limited", server prices, "hcloud CLI", "Versions on
2026-09-19"). Record those as done, pointing at `research.md`; do not
re-run them.

What no document settles is Hetzner's own behaviour: whether a CSI volume
survives the deletion of the server holding it and gives its data back,
whether a load balancer is deleted with its Service and what becomes of it
when the servers die first, the account limits against the four-node
shape, and the invoice lines. Those four are the spike.

Two things it no longer has to prove. The bootstrap is `curl -sfL
https://get.k3s.io | … sh -`, which either returns 0 or does not, so it
needs no rehearsal; and the cloud-controller-manager ordering argument is
unchanged from the kubeadm design except that k3s's bundled CoreDNS stands
where kubeadm's did, so item 1 confirms it while bringing the cluster up
rather than as a staged experiment of its own.

## 2. Scope and non-goals

In scope: up to three `cx33` servers in `nbg1`, one private network, one
firewall, one volume, one load balancer, one throwaway k3s install with the
hcloud CCM and CSI, created and destroyed by hand or with throwaway
Terraform in a scratch directory that never goes under
`terraform/live/`. Not in scope: repository code, Argo CD beyond a Healthy
check, AWS changes, and the cluster autoscaler component itself — item 4
boots one server from the worker cloud-init, which is what the autoscaler
will do; it does not deploy HETZ-170.

Prerequisites, outside this repository: a Hetzner account past identity
verification, a project `vk-hetzner-spike` (never the lab project), one
Read&Write token exported as `HCLOUD_TOKEN` for the session only, `hcloud`
CLI ≥ 1.68, `helm`, `kubectl`.

## 3. Current state / evidence

`research.md` already answers, at high confidence from real creates and
reads on 2026-09-19, what the previous spike plan could not: `cx33`
create/delete in `nbg1`/`fsn1`/`hel1`, the API price list, and the pinned
tool versions — `hcloud` CLI 1.68.0, Terraform provider
`hetznercloud/hcloud` 1.69.0, hcloud CCM v1.37.0, hcloud-csi v2.23.0
("Versions on 2026-09-19" row). Those facts are done. The k3s version the
spike installs is the one HETZ-030 pins as `K3S_VERSION`.

What `research.md` still marks as inferred from manifests or docs, never
run, or medium/low confidence:

- k3s's bundled CoreDNS tolerations exclude `uninitialized`; the CCM chart
  tolerates it and clears the taint — inferred from the k3s CoreDNS
  manifest and the CCM chart template, never run end to end.
- flannel's VXLAN datapath over the hcloud private network with
  `--flannel-iface=enp7s0`, and that the MTU 1450 NIC needs no override —
  documented, unmeasured on a real `cx33`.
- That `--disable=servicelb,traefik,local-storage` leaves no trace, and
  that `--cluster-init` gives an etcd datastore `k3s etcd-snapshot save`
  can write.
- CSI volume survival after server deletion, and data readback after
  re-attachment to another server — low confidence, "spike must verify"
  (Volumes row).
- LB creation and deletion with the Service, and whether the LB is
  orphaned when servers die first — medium confidence, "deletion path not
  spelled out … spike verifies" (CCM load balancer annotations row).
- Firewall behaviour for LB → node traffic with `use-private-ip` — medium
  confidence (LB → node traffic row).
- That a server booted from the worker cloud-init alone joins with no
  operator step, which is what the autoscaler depends on.
- Metadata `userdata` exposure, including the k3s join token, on such a
  node — the mechanism is documented (metadata service row) and ADR 0037
  accepts it, but it is not exercised on this node shape.
- The 5-server default limit against 4 lab nodes (1 cp + 1 worker + up to
  2 autoscaled) plus CI's own nodes — medium confidence (Default limits
  row).
- Invoice lines for network, firewall, SSH key, unassigned primary IP,
  hourly rounding, and the actual volume/LB rates — medium confidence,
  list price only.

## 4. Design and contracts

Checklist. For each item record the command, the result, and the date in
the report.

1. Create two `cx33` in `nbg1` at the same time, with the HETZ-030
   cloud-init templates: the first as `k3s server` with `--cluster-init`
   and the full flag set, the second as `k3s agent` with `K3S_URL` and the
   same token. Record the time from create to each node registering, and
   to both reporting `Ready` — that figure is what HETZ-040's wait budget
   is sized against. Then confirm, in one pass:
   - both nodes `Ready`, both carrying
     `node.cloudprovider.kubernetes.io/uninitialized`, CoreDNS `Pending`;
   - no `traefik`, `svclb-` or `local-path-provisioner` pod, no
     `local-path` StorageClass, and metrics-server present;
   - `k3s etcd-snapshot save` succeeds, proving embedded etcd;
   - a two-pod cross-node ping over flannel VXLAN succeeds at MTU 1450;
   - allocatable CPU and memory on a `cx33` with the CCM and CSI running.
   Fetch `/etc/rancher/k3s/k3s.yaml` over SSH and rewrite its address.
   Create the in-cluster token Secret, then `helm install hccm
   hcloud/hcloud-cloud-controller-manager -n kube-system --set
   networking.enabled=true --set networking.clusterCIDR=10.42.0.0/16 --set
   env.HCLOUD_NETWORK_ROUTES_ENABLED.value=false`. Record the time until
   the taint clears, `providerID` is set, and CoreDNS reaches `Running`.
   Helm-install Argo CD with the repository's values and confirm it
   reaches `Healthy`. Record every timing.
2. Install `hcloud/hcloud-csi` 2.23.0. Create a 10 Gi PVC and write a
   marker file. Delete the server holding the volume. `hcloud volume
   list`. Re-attach the volume to the other server and read the marker.
   Note whether the charge line kept running.
3. Create a `type: LoadBalancer` Service with `load-balancer.hetzner.cloud/
   location: nbg1`, `use-private-ip: "true"`, `ipv6-disabled: "true"`.
   Time to `status.loadBalancer.ingress`; record whether `.ip` or
   `.hostname` is set. `curl` through it with the server firewall allowing
   only 22 and 6443. Delete the Service and confirm the LB is gone.
   Recreate the Service, then delete every server while the LB exists:
   record whether the LB is orphaned.
4. Create a third `cx33` by hand with the **same** worker cloud-init the
   second server used, unchanged — that is exactly what the autoscaler
   will do (HETZ-170). Confirm it joins with no further step, gets a
   `providerID`, and becomes `Ready`. From a `hostNetwork` pod on it,
   `curl 169.254.169.254/hetzner/v1/userdata` and record that the k3s join
   token is readable there, so ADR 0037's accepted exposure is on record as
   observed rather than inferred. Delete the server.
5. Console → Limits: record the server and primary-IP limits. Decide
   whether a limit-increase request is needed before M1 (4 lab nodes plus
   CI's own nodes).
6. Destroy everything. `hcloud {server,load-balancer,volume,firewall,
   network,primary-ip,ssh-key} list` must all be empty. Next day, read the
   invoice: lines for network, firewall, SSH key, unassigned primary IP;
   hourly rounding; the actual volume and LB rates.

Ceiling: 1 EUR. Stop and destroy if the running total approaches it.

## 4a. Deviations from §2 and §4

- **D1 — one project, not `vk-hetzner-spike`.** §2 requires a separate spike
  project. Operator decision: the spike ran in the platform's own `vk-lab`
  project, which was empty. The rule exists because `hcloud_ssh_key` names are
  unique per project (HETZ-025 §12), so every spike resource was named
  `hz020-*` and labelled `spike=hetz-020`, and §6's sweep was run
  **unfiltered** rather than by label. Baseline before and sweep after were
  both zero across all ten resource kinds.
- **D2 — the Console project name.** `secrets/README.md` told the operator to
  name the Hetzner project `vk-hetzner-lab`; the real one is `vk-lab`. Nothing
  reads the Console name — the token selects the project and labels use
  `PROJECT_NAME` — so the documentation was corrected to say so rather than
  the project renamed.
- **D3 — item 1's templates had to be written, not reused.** §4 says "with the
  HETZ-030 cloud-init templates". They do not exist: a sweep for
  `get.k3s.io|INSTALL_K3S|K3S_URL|K3S_TOKEN|flannel-iface|enp7s0|cluster-init|
  #cloud-config|user_data` across every `.tf`, `.sh`, `.yaml`, `.tpl` and the
  Makefile returns zero hits, and there is no `terraform/live/cluster-hetzner/`
  or `terraform/modules/*hcloud*`. The two fenced blocks in HETZ-030
  `:178-192` and `:209-218` were transcribed into throwaway documents in the
  session scratchpad. HETZ-017's blocks at `:123-147` are an earlier, less
  complete draft and must not be used.
- **D4 — three of the prescribed commands are wrong and were fixed to run.**
  Recorded in full in `research.md`'s Spike results: the unquoted
  `eviction-hard` redirect, the `$PRIV` parse, and §4 item 1's own
  `--set env.HCLOUD_NETWORK_ROUTES_ENABLED.value=false`, which must be
  `--set-string`. Each is a defect in a spec, not in Hetzner.
- **D5 — item 5's CAX half could not run.** The plan added a `cax21` create to
  settle whether the ARM fallback had returned. Hetzner refused it
  (`unsupported location for server type`), which is itself the answer, so the
  autoscaler-node test of item 4 was run on `cx33` instead. The refusal also
  exposed that HETZ-175 §4's pre-flight probe reads a field that does not
  predict creates.
- **D6 — the `K3S_VERSION` pin is a deliverable §4 does not name.** Nothing in
  the repository pinned one. The spike chose and proved `v1.36.4+k3s1`.
- **D7 — item 5 (limits) and item 6's invoice line remain open.** No API
  exposes account limits, and the invoice is not available until the next
  billing day. Both are recorded as operator actions in the Spike results.

## 5. Files/components affected

- `specs/hetzner/research.md` (new "Spike results" section, answering the
  low/medium-confidence rows listed in §3).
- `specs/hetzner/decisions.md` (confirms or amends the rows: Node shape
  (`cx33`), CCM before Argo (ordering proven end to end), Stable LB address
  (orphaning behaviour), Autoscaler credential (token TTL and metadata
  exposure)).

## 6. Implementation steps

1. Prepare the spike project and token; export `HCLOUD_TOKEN` for the
   session only.
2. Run checklist item 1; keep timestamps.
3. Run checklist items 2–3.
4. Run checklist items 4–5.
5. Run checklist item 6; write the report, correct the research rows, and
   amend `decisions.md`.

## 7. Dependencies and blockers

None in the repository. Blocked in practice until the account, project and
token exist. Needs only the Hetzner account, a spike project, one R&W
token exported for the session, `hcloud` CLI ≥ 1.68, `helm`, `kubectl`.

## 8. Acceptance criteria

- Every checklist item (§4, 1–6) has a recorded result, with date and the
  command run, or a recorded reason it could not run.
- Item 1 shows the CoreDNS `Pending` → `Running` transition with timings
  (boot → both nodes Ready → CCM → CoreDNS `Running` → Argo CD `Healthy`),
  and records that the three disabled components left no trace and that
  `k3s etcd-snapshot save` succeeded.
- Item 2 answers both halves: volume survival and data readback.
- Item 3 answers LB deletion with the Service and orphaning when servers
  die first.
- Item 4 shows a node joining from the unmodified worker cloud-init with
  no operator step.
- The final listings in item 6 are empty; the invoice shows the expected
  lines only.
- The report is committed to `specs/hetzner/research.md`.

## 9. Validation

The report is the deliverable. The leak check and the invoice are the
validation. Cost: under 1 EUR.

## 10. AWS regression protection

No repository code changes. No AWS or Civo resource is touched; the spike
uses no AWS credentials.

## 11. Rollout and rollback/recovery

Nothing to roll back. If a resource resists deletion, delete it in the
Console and record why.

## 12. Risks and unresolved questions

- CAX absence is already recorded (`research.md`, `decisions.md`); this
  spike does not re-test it.
- `cx33` stock can change between the spike and M1; HETZ-175 owns the
  stock-aware fallback if it does.
- The repository's Argo CD helm values may need `--set` overrides to run
  standalone outside the platform's `argo-up`/Terraform inputs; record any
  override used.
- The k3s join token does not expire, so item 4 needs no TTL handling;
  what it must not do is edit the worker cloud-init, because the point is
  that the autoscaler's node and the fixed worker boot the same bytes.

## 13. Definition of done

- [ ] Report written and research rows corrected in `research.md`
- [ ] `decisions.md` rows confirmed or amended
- [ ] Leak check empty; invoice read; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — rewritten for kubeadm and shrunk: create/delete, stock,
  prices and versions were proven on 2026-09-19 (research.md); node shape
  is cx33 (decisions.md).
- 2026-09-20 — option C: item 1 records the boot-to-marker time, because
  the product runs init and Cilium from the control plane's cloud-init
  (decisions.md §3, "Bootstrap driver").
- 2026-09-20 — review fix: item 1's Cilium values match the product's
  (`routingMode=tunnel`, `tunnelProtocol=vxlan`, `operator.replicas=1`),
  and the timing to record is stated per path.
- 2026-09-20 — k3s (HETZ-017, ADR 0037); seven items become six, and the
  kubeadm rehearsal goes. The bootstrap is one install command that either
  returns 0 or does not, so items 1 and 2 collapse into a single
  bring-up-and-observe pass that also checks the three disabled components,
  embedded etcd and the flannel datapath. Item 4 no longer mints a token
  and writes a join line: it boots a third server from the unmodified
  worker cloud-init, which is what the autoscaler does. The four items that
  carried the spike's real value — volume survival, load balancer
  lifecycle and orphaning, account limits, invoice — are unchanged, and
  they are the reason this spec still exists.
- 2026-09-21 — executed on branch `hetzner-020-feasibility-spike`, off `main`
  at `07f7dcb`. Deviations D1 to D7 in §4a. Full report in
  `specs/hetzner/research.md` under "Spike results (HETZ-020, 2026-09-21)";
  four rows amended in `decisions.md`; experiments 2, 3, 4, 5, 6 struck and 8
  struck in part in `research.md`'s open list.

  Checklist coverage: item 1 done (bring-up, ordering, disabled components,
  etcd snapshot, flannel datapath, allocatable); item 2 done (volume survives
  and data reads back, with a ~6-minute force-detach stall); item 3 done
  (address shape, traffic with no NodePort rule, clean deletion with the
  Service, **orphaning confirmed**); item 4 done on `cx33` per D5, including
  the `userdata` token exposure; item 5 open (limits are Console-only); item 6
  done for the sweep, open for the invoice.

  Five defects found in commands the specs prescribe verbatim — HETZ-030's
  `eviction-hard` quoting and `$PRIV` parse, HETZ-020 §4's own CCM helm flag,
  HETZ-175 §4's pre-flight probe field, and the hcloud CLI's inability to pin
  a private IP at create.

  Leak sweep clean: server, load-balancer, volume, firewall, network,
  primary-ip, ssh-key, placement-group, floating-ip and certificate all zero,
  unfiltered, matching the pre-spike baseline. Measured spend about 0.03 EUR
  against the 1 EUR ceiling; the invoice confirms it next billing day.
