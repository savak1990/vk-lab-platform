---
id: "HETZ-020"
title: "Feasibility spike: a throwaway k3s cluster on hcloud servers, with a written report"
status: "READY"
priority: "P0"
milestone: "M0"
type: "research"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Procedural verification with a fixed checklist; findings matter more than design reasoning"
effort_estimate: "One session (4–6 h) plus boot waits; cost under 2 EUR"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-020 — Feasibility spike

## 1. Outcome and rationale

The outcome is a written report in `specs/hetzner/research.md` (new section
"Spike results"). The report answers the questions that block HETZ-030,
HETZ-040, HETZ-045 and HETZ-120. The answers come from real servers. Planning
settled the CSI snapshot question from source; it cannot settle boot
ordering, stock, allocatable memory, volume survival, or LB deletion from
documentation.

## 2. Scope and non-goals

In scope: up to three `cax21` servers in `nbg1`, one private network, one
firewall, one volume, one load balancer, one throwaway k3s install with the
hcloud CCM and CSI, created and destroyed by hand or with throwaway
Terraform in the scratch directory. That Terraform never goes under
`terraform/live/`. Not in scope: repository code, Argo, AWS changes, and the
cluster autoscaler beyond experiment 8.

Prerequisites, outside this repository: a Hetzner account past
identity verification, a project `vk-hetzner-spike` (never the lab project),
one Read&Write token exported as `HCLOUD_TOKEN` for the session only, and the
`hcloud` CLI.

## 3. Current state / evidence

`research.md` has these items at low or medium confidence, or marked "spike":

- CAX stock in `nbg1` and the exact `server_type` and arm64 image strings — medium, third-party trackers.
- Allocatable memory on CAX21 with k3s, CCM and CSI running — unmeasured.
- Volume survival after server deletion and data readback after re-attachment — low.
- LB created and deleted with the Service; LB orphaned if servers die first — medium.
- The uninitialised taint blocks CoreDNS; the CCM clears it (decisions.md, CCM ordering) — inferred from manifests, not run.
- Private NIC name for `--flannel-iface` on the arm64 Ubuntu image — unknown.
- Firewall behaviour for LB → node traffic with `use-private-ip` — medium.
- Autoscaler scale-from-zero — unverified.
- Invoice lines for network, firewall, SSH key, unassigned primary IP; hourly rounding; actual volume €/GB — medium.
- Default limit of 5 servers and whether a limit request is needed before M1 — medium.

## 4. Design and contracts

Checklist. For each item record the command, the result, and the date in the report.

1. `hcloud server-type list` and `hcloud image list --type system --architecture arm`: record the exact `cax21` name, price fields, and the arm64 `ubuntu-24.04` image name. Then `hcloud server create --type cax21 --location nbg1 --image ubuntu-24.04 --ssh-key <spike> --name spike-cp` and note whether stock rejects it.
2. On the server: `ip -o link` and `ip -o addr` after attaching the private network; record the private NIC name and whether the metadata path `169.254.169.254/hetzner/v1/metadata/private-networks` lists it. Record `curl 169.254.169.254/hetzner/v1/metadata/public-ipv4`.
3. Boot k3s with the HETZ-030 flag set (`--disable-cloud-controller`, `--disable servicelb,traefik`, `--kubelet-arg cloud-provider=external`, `--node-ip`, `--node-external-ip`, `--tls-san`, `--flannel-iface`). Fetch `/etc/rancher/k3s/k3s.yaml` over SSH, rewrite the server address, run `kubectl get nodes,pods -A`. Confirm the node is Ready but tainted `node.cloudprovider.kubernetes.io/uninitialized` and that CoreDNS is Pending.
4. Create Secret `kube-system/hcloud` (`token`, `network`). `helm install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --set networking.enabled=true --set networking.clusterCIDR=10.42.0.0/16 --set env.HCLOUD_NETWORK_ROUTES_ENABLED.value=false`. Time until the taint clears and CoreDNS is Running. Then helm-install Argo CD with the repository's values and confirm it reaches Healthy. This proves the ordering decision end to end.
5. Join two agents. Record `kubectl get node -o json` allocatable CPU and memory on a CAX21 with CCM and CSI pods present. Record `kube-system` requests.
6. Install `hcloud/hcloud-csi`. Create a 10 Gi PVC and write a marker file. Delete the server that holds it. `hcloud volume list`: state, size, server field. Attach the volume to another server, mount it, read the marker. Record whether the charge line kept running.
7. Create a `type: LoadBalancer` Service with `load-balancer.hetzner.cloud/location: nbg1`, `use-private-ip: "true"`, `ipv6-disabled: "true"`. Time to `status.loadBalancer.ingress`; record whether `.ip` or `.hostname` is set; `curl` through it with the server firewall allowing only 22 and 6443. Delete the Service; confirm the LB is gone. Recreate the Service, then delete all servers while the LB exists: confirm whether the LB is orphaned.
8. Deploy the cluster autoscaler with `--nodes=0:1:CAX21:NBG1:workers` and a cloud-init that joins with the k3s token. Create an unschedulable pod. Record whether a server appears, joins, and gets a `providerID`. Scale back down.
9. From a `hostNetwork` pod: `curl 169.254.169.254/hetzner/v1/userdata`. Record that the cloud-init, including the join token, is readable.
10. `hcloud server list -l project=spike -o json` and the same for load-balancer, volume, firewall, primary-ip: confirm label selectors work for the sweep.
11. Console → Limits: record the server and primary-IP limits. Decide whether a limit request is needed before M1 (3 lab + 3 CI nodes + autoscaler headroom).
12. Destroy everything. `hcloud {server,load-balancer,volume,firewall,network,primary-ip,ssh-key} list` must be empty. Next day, read the invoice: lines for network, firewall, SSH key, unassigned primary IP; hourly rounding; volume and LB rates.

Ceiling: 2 EUR. Stop and destroy if the running total approaches it.

## 5. Files/components affected

- `specs/hetzner/research.md` (new "Spike results" section; low-confidence rows corrected).
- `specs/hetzner/decisions.md` (control-plane topology, CCM ordering, and metrics-server rows confirmed or amended).
- `specs/hetzner/030-…/spec.md` (image name, NIC name, flags), `040-…` (readiness timing), `045-…` (taint-clear timing), `120-…` (volume survival), `170-…` (scale-from-zero).
- `specs/hetzner/README.md` (index).

## 6. Implementation steps

1. Prepare the scratch Terraform or shell script; export `HCLOUD_TOKEN` for the shell only.
2. Run items 1–11 in order; keep timestamps.
3. Run item 12; wait for the invoice.
4. Write the report; correct the research rows; amend the dependent specs; open no PR unless the operator asks.

## 7. Dependencies and blockers

None in the repository. Blocked in practice until the account, project and token exist.

## 8. Acceptance criteria

- Every checklist item has a recorded result or a recorded reason it could not run.
- Items 3–4 give a definite answer to "does the CCM clear the taint and let CoreDNS and Argo CD start", with timings.
- Item 6 answers both halves: object survival and data readback.
- Item 7 answers LB deletion with the Service and orphaning without the CCM.
- The final listings are empty; the invoice shows the expected lines only.

## 9. Validation

The report is the deliverable. The leak check and the invoice are the validation. Cost: under 2 EUR.

## 10. AWS regression protection

No repository code changes. No AWS or Civo resource is touched; the spike uses no AWS credentials.

## 11. Rollout and rollback/recovery

Nothing to roll back. If a resource resists deletion, delete it in the Console and record why.

## 12. Risks and unresolved questions

- CAX21 may be out of stock at spike time. Fall back to `cax11` for the same experiments and record the substitution; if all CAX are unavailable, run on `cpx22` and flag HETZ-175 as P1.
- The new-account server limit may be below three; run items 1–7 on two servers if so.
- Item 8 may exhaust the API rate limit if the autoscaler misbehaves; run it last before teardown.

## 13. Definition of done

- [ ] Report written and research rows corrected
- [ ] Dependent specs amended
- [ ] Leak check empty; invoice read; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
