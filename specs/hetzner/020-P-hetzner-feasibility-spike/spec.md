---
id: "HETZ-020"
title: "Feasibility spike: kubeadm, Cilium and the hcloud CCM on throwaway cx33 servers, with a written report"
status: "READY"
priority: "P0"
milestone: "M0"
type: "research"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Procedural verification with a fixed checklist; findings matter more than design reasoning"
effort_estimate: "Half a session (2–3 h) plus boot waits and one invoice read; cost under 1 EUR"
estimate_confidence: "medium"
depends_on: []
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
re-run them. What no document settles is whether kubeadm's CoreDNS
tolerations, Cilium's VXLAN datapath and the hcloud CCM actually clear the
`uninitialized` taint in the order `decisions.md` assumes, whether a CSI
volume and a load balancer survive the lifecycle events the CCM contract
implies, and the account limits and invoice lines for the now-smaller
1 cp + 1 worker + autoscaled-worker shape.

## 2. Scope and non-goals

In scope: up to three `cx33` servers in `nbg1`, one private network, one
firewall, one volume, one load balancer, one throwaway kubeadm install with
Cilium, the hcloud CCM and CSI, created and destroyed by hand or with
throwaway Terraform in a scratch directory that never goes under
`terraform/live/`. Not in scope: repository code, Argo CD beyond a Healthy
check, AWS changes, and the cluster autoscaler component itself — item 5
performs a manual `kubeadm join` shaped like the autoscaler's join; it does
not deploy HETZ-170.

Prerequisites, outside this repository: a Hetzner account past identity
verification, a project `vk-hetzner-spike` (never the lab project), one
Read&Write token exported as `HCLOUD_TOKEN` for the session only, `hcloud`
CLI ≥ 1.68, `helm`, `kubectl`.

## 3. Current state / evidence

`research.md` already answers, at high confidence from real creates and
reads on 2026-09-19, what the previous spike plan could not: `cx33`
create/delete in `nbg1`/`fsn1`/`hel1`, the API price list, and the pinned
tool versions — `hcloud` CLI 1.68.0, Terraform provider
`hetznercloud/hcloud` 1.69.0, Kubernetes 1.36.4, `containerd.io` 2.3, Cilium
1.20.2, hcloud CCM v1.37.0, hcloud-csi v2.23.0 ("Versions on 2026-09-19"
row). Those facts are done.

What `research.md` still marks as inferred from manifests or docs, never
run, or medium/low confidence:

- kubeadm's CoreDNS tolerations exclude `uninitialized`; the CCM chart
  tolerates it and clears the taint — inferred from `dns/manifests.go` and
  the CCM chart template, never run end to end ("kubeadm CoreDNS
  tolerations vs. CCM" row).
- Cilium's VXLAN datapath over the hcloud private network, with
  `ipam.mode=kubernetes` avoiding the pod-CIDR collision — documented,
  unmeasured on a real `cx33` NIC ("Cilium 1.20.2 on Hetzner" row).
- CSI volume survival after server deletion, and data readback after
  re-attachment to another server — low confidence, "spike must verify"
  (Volumes row).
- LB creation and deletion with the Service, and whether the LB is
  orphaned when servers die first — medium confidence, "deletion path not
  spelled out … spike verifies" (CCM load balancer annotations row).
- Firewall behaviour for LB → node traffic with `use-private-ip` — medium
  confidence (LB → node traffic row).
- An autoscaler-style `kubeadm join` from a cloud-init using a `--ttl 0`
  token — unverified (cluster autoscaler row, open experiment 8).
- Metadata `userdata` exposure, including the join token, on such a node —
  the mechanism is documented (metadata service row) but not exercised on
  this node shape.
- The 5-server default limit against 4 lab nodes (1 cp + 1 worker + up to
  2 autoscaled) plus CI's own nodes — medium confidence (Default limits
  row).
- Invoice lines for network, firewall, SSH key, unassigned primary IP,
  hourly rounding, and the actual volume/LB rates — medium confidence,
  list price only.

## 4. Design and contracts

Checklist. For each item record the command, the result, and the date in
the report.

1. Create two `cx33` in `nbg1` with a cloud-init that installs
   `containerd.io` 2.3 from Docker's repo, `kubeadm`/`kubelet`/`kubectl`
   1.36 from `pkgs.k8s.io`, the `overlay`/`br_netfilter` modules, the
   sysctls, and turns swap off. Run `kubeadm init --config` on the first
   server with `nodeRegistration.kubeletExtraArgs` `cloud-provider:
   external` and `node-ip` set to the private address,
   `nodeRegistration.taints: []`, `networking.podSubnet: 10.244.0.0/16`,
   `controlPlaneEndpoint: 10.0.1.10:6443`, `apiServer.certSANs: [<public
   ip>]`. In the product these steps are the control plane's own
   cloud-init (HETZ-030); the spike may run them by hand or from a
   cloud-init copy of `control-plane.yaml.tftpl`. On the cloud-init path,
   record the time from create to `/var/lib/lab/cp-bootstrap-done`; on the
   by-hand path, record the time from create to the control plane turning
   `Ready`. Either figure is what HETZ-035's wait budget is sized
   against. Fetch `/etc/kubernetes/admin.conf` over
   SSH. Confirm the node is
   `NotReady` with the `node.cloudprovider.kubernetes.io/uninitialized`
   taint and CoreDNS `Pending`. `helm install cilium cilium/cilium
   --version 1.20.2 -n kube-system --set ipam.mode=kubernetes --set
   routingMode=tunnel --set tunnelProtocol=vxlan --set
   kubeProxyReplacement=false --set operator.replicas=1`, the product's
   own value set (HETZ-037); confirm the node turns `Ready` while
   CoreDNS stays `Pending`. Create Secret `kube-system/hcloud`. `helm
   install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --set
   networking.enabled=true --set networking.clusterCIDR=10.244.0.0/16`.
   Record the time until the taint clears, `providerID` is set on the
   node, and CoreDNS reaches `Running`. Helm-install Argo CD with the
   repository's values and confirm it reaches `Healthy`. Record every
   timing.
2. `kubeadm join` the second server using the `--print-join-command`
   output plus `--cloud-provider=external`/`--node-ip` kubelet args.
   Record `kubectl get node -o json` allocatable CPU and memory on a
   `cx33` with Cilium, the CCM and CSI pods present.
3. Install `hcloud/hcloud-csi` 2.23.0. Create a 10 Gi PVC and write a
   marker file. Delete the server holding the volume. `hcloud volume
   list`. Re-attach the volume to the other server and read the marker.
   Note whether the charge line kept running.
4. Create a `type: LoadBalancer` Service with `load-balancer.hetzner.cloud/
   location: nbg1`, `use-private-ip: "true"`, `ipv6-disabled: "true"`.
   Time to `status.loadBalancer.ingress`; record whether `.ip` or
   `.hostname` is set. `curl` through it with the server firewall allowing
   only 22 and 6443. Delete the Service and confirm the LB is gone.
   Recreate the Service, then delete every server while the LB exists:
   record whether the LB is orphaned.
5. `kubeadm token create --ttl 0 --print-join-command` on the control
   plane. Create a third `cx33` by hand with a cloud-init that installs
   the same packages and runs that join command with
   `KUBELET_EXTRA_ARGS=--cloud-provider=external --node-ip=<metadata
   private ip>`. Confirm it joins, gets a `providerID`, and becomes
   `Ready`. From a `hostNetwork` pod on it, `curl
   169.254.169.254/hetzner/v1/userdata` and record that the join token is
   readable there. Delete the server.
6. Console → Limits: record the server and primary-IP limits. Decide
   whether a limit-increase request is needed before M1 (4 lab nodes plus
   CI's own nodes).
7. Destroy everything. `hcloud {server,load-balancer,volume,firewall,
   network,primary-ip,ssh-key} list` must all be empty. Next day, read the
   invoice: lines for network, firewall, SSH key, unassigned primary IP;
   hourly rounding; the actual volume and LB rates.

Ceiling: 1 EUR. Stop and destroy if the running total approaches it.

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
2. Run checklist items 1–2; keep timestamps.
3. Run checklist items 3–4.
4. Run checklist items 5–6.
5. Run checklist item 7; write the report, correct the research rows, and
   amend `decisions.md`.

## 7. Dependencies and blockers

None in the repository. Blocked in practice until the account, project and
token exist. Needs only the Hetzner account, a spike project, one R&W
token exported for the session, `hcloud` CLI ≥ 1.68, `helm`, `kubectl`.

## 8. Acceptance criteria

- Every checklist item (§4, 1–7) has a recorded result, with date and the
  command run, or a recorded reason it could not run.
- Item 1 shows the CoreDNS `Pending` → `Running` transition with timings
  (init → Cilium → CCM → CoreDNS `Running` → Argo CD `Healthy`).
- Item 3 answers both halves: volume survival and data readback.
- Item 4 answers LB deletion with the Service and orphaning when servers
  die first.
- The final listings in item 7 are empty; the invoice shows the expected
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
- Bootstrap tokens default to a 24 h TTL. Item 5 must pass `--ttl 0`
  explicitly, or the token used for the manual join expires mid-spike.

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
