---
id: "HETZ-037"
title: "Cilium from the control plane's cloud-init; cluster-up ends when every node is Ready"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "One helm release with fixed values, placed in a template another spec renders, plus a bounded wait; the judgement is in the values and the connectivity test"
effort_estimate: "Half a session (2–3 h) plus waits"
estimate_confidence: "medium"
depends_on: ["HETZ-035"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-20"
completed: ""
---

# HETZ-037 — Cilium CNI

## 1. Outcome and rationale

kubeadm ships no CNI — this is the exam's own "install a Pod network
add-on" step — so without it every node stays `NotReady` and nothing
schedules. Cilium is therefore installed by the control plane's own
cloud-init, right after its boot-time `kubeadm init` (HETZ-030), which
means the CNI is already up before the first worker joins. This spec owns
what that install *is*: the helm values, the `CILIUM_CHART_VERSION` pin
that reaches the template as `TF_VAR_cilium_chart_version`, and
`wait_for_nodes_ready()` in `scripts/hetzner-bootstrap.sh` after the
joins. `PROVIDER=hetzner make cluster-up` succeeds only once every node is
`Ready`; a timed-out wait fails the recipe.

## 2. Scope and non-goals

In scope: the Cilium helm values and the `helm` lines they become in
HETZ-030's `templates/control-plane.yaml.tftpl`,
`scripts/lib/versions.sh`'s `CILIUM_CHART_VERSION` and its export as
`TF_VAR_cilium_chart_version`, `wait_for_nodes_ready()` in
`scripts/hetzner-bootstrap.sh`, and the hetzner arm of the `cluster-up`
Make target insofar as its exit status now depends on
`wait_for_nodes_ready`. The template file itself belongs to HETZ-030;
this spec supplies its Cilium content and no other part of it.
Not in scope: the cloud controller manager and CSI driver (HETZ-045,
HETZ-050) — CoreDNS staying `Pending` after this spec's work is their
concern, not this one's; the connectivity test's pod manifests exist only
as a one-off check in §8, not as a committed file; the autoscaler join
path (HETZ-170); native routing mode (§12).

## 3. Current state / evidence

- HETZ-030's control-plane cloud-init runs `kubeadm init` and then the
  helm install this spec specifies, and marks
  `/var/lib/lab/cp-bootstrap-done` when both have returned. HETZ-035's
  `kubeadm_join_workers()` then joins every worker, and its
  `wait_for_api()` polls `/readyz` only, deliberately not `Ready` nodes,
  which is this spec's wait. HETZ-035 also fixes the kubeconfig contract
  this spec reuses unchanged: `admin.conf` fetched into the isolated
  kubeconfig (ADR 0034), context `${PROJECT_NAME}-hetzner`.
- Cilium 1.20.2's default datapath is VXLAN (8472/UDP), needing no CCM
  route programming; `ipam.mode=kubernetes` is required because Cilium's
  own cluster-pool default (`10.0.0.0/8`) collides with the hcloud private
  network, while kubeadm's `networking.podSubnet` (`10.244.0.0/16`, set by
  HETZ-030's kubeadm config) is collision-free.
  https://docs.cilium.io/en/stable/network/concepts/routing/ ;
  https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/
- `kubeProxyReplacement=false` keeps kube-proxy, the kubeadm default and
  the shape the CKA exam assumes; the Cilium DaemonSet's own tolerations
  (`operator: Exists`) mean it schedules on a node that still carries the
  `uninitialized` taint, unlike kubeadm's CoreDNS.
  https://docs.cilium.io/en/stable/network/concepts/ipam/kubernetes/
- Cilium 1.20.2's documented Kubernetes compatibility is 1.33–1.36, which
  covers `KUBERNETES_VERSION` (1.36.x, HETZ-030).
  https://docs.cilium.io/en/stable/network/kubernetes/compatibility/
- The private NIC on `cx33` is `enp7s0` at MTU 1450; Cilium auto-detects
  MTU rather than taking a fixed value.
  https://docs.hetzner.com/networking/networks/server-configuration/
- decisions.md §3, "CCM before Argo": kubeadm's own CoreDNS Deployment
  tolerates `CriticalAddonsOnly` and the control-plane taint only, not
  `uninitialized`, so it stays `Pending` once Cilium is up and until
  HETZ-045's cloud controller manager clears the taint — expected here,
  not a failure of this spec.
  https://kubernetes.io/blog/2025/02/14/cloud-controller-manager-chicken-egg-problem/
- The hcloud firewall (HETZ-030) filters only the public interface; VXLAN
  traffic travels over the private network, which it does not filter, so
  this spec adds no firewall rule.

## 4. Design and contracts

The install is a `runcmd` block in HETZ-030's
`templates/control-plane.yaml.tftpl`, after `kubeadm init`; the wait is a
function in `scripts/hetzner-bootstrap.sh`, called after
`kubeadm_join_workers()` returns.

- The install: `helm repo add cilium https://helm.cilium.io` (itself
  idempotent), then `helm upgrade --install cilium cilium/cilium --version
  ${cilium_chart_version} -n kube-system --set ipam.mode=kubernetes --set
  routingMode=tunnel --set tunnelProtocol=vxlan --set
  kubeProxyReplacement=false --set operator.replicas=1 --kubeconfig
  /etc/kubernetes/admin.conf`. `ipam.mode=kubernetes` avoids the
  cluster-pool default's collision with the hcloud private network;
  `routingMode=tunnel` with `tunnelProtocol=vxlan` is the documented
  default datapath and needs no CCM route programming;
  `kubeProxyReplacement=false` keeps kube-proxy, which is kubeadm's own
  shape and the exam's; `operator.replicas=1` matches the node count
  (research.md, "Cilium 1.20.2 on Hetzner"). No
  `k8sServiceHost`/`k8sServicePort` value is set — that pair only matters
  when Cilium replaces kube-proxy, which this does not. No `--wait`: the
  boot marker means the release was created, and this spec's own wait is
  what proves health. The release sits outside Argo CD's tree, the same
  untracked-helm-release shape as Argo CD itself and the coming CCM
  (decisions.md §3); `argo-up` never touches Cilium.
- `CILIUM_CHART_VERSION=1.20.2` lives in `scripts/lib/versions.sh`
  alongside `KUBERNETES_VERSION`, and the hetzner `cluster-up` arm exports
  it as `TF_VAR_cilium_chart_version` so the template's
  `${cilium_chart_version}` resolves; the Terraform variable has no
  default, so a missing export fails the apply rather than pinning a stale
  chart.
- Cloud-init runs once per server lifetime, so the install happens exactly
  once however many times `cluster-up` runs — the idempotence that
  HETZ-035 gets from its per-worker file checks, this spec gets from the
  boot sequence itself.
- `wait_for_nodes_ready()`: polls `kubectl get nodes` every 10 s until
  every node's `Ready` condition is `True`, bounded by
  `HETZNER_NODE_READY_SECONDS` (default 600), matching the
  `HETZNER_*`-prefixed env-var style HETZ-035 and HETZ-040 use. On
  timeout it prints the full node list and `kubectl -n kube-system get
  pods`, then exits 1 — giving the operator the CNI DaemonSet's own state
  without a second manual command.
- The hetzner arm of the `cluster-up` Make target already runs
  `scripts/hetzner-bootstrap.sh`; no new Make target is added. The
  recipe's exit status now covers `wait_for_nodes_ready`'s bound, so a
  timed-out wait fails `make cluster-up` the same way a failed
  `terragrunt apply` does.
- Connectivity test (§8 only, not committed to the script or the repo):
  two `busybox` pods, each pinned to a different node with
  `tolerations: [{operator: Exists}]` (needed because the `uninitialized`
  taint is still present at this point in the sequence), ping each
  other's pod IP.

## 5. Files/components affected

`terraform/modules/hcloud-nodes/templates/control-plane.yaml.tftpl`
(HETZ-030's file; this spec supplies its Cilium `runcmd` lines and the
`cilium_chart_version` variable they read);
`scripts/hetzner-bootstrap.sh` (adds `wait_for_nodes_ready()` and its call
after `kubeadm_join_workers()`); `scripts/lib/versions.sh`
(`CILIUM_CHART_VERSION`); `Makefile` (no new target; the hetzner
`cluster-up` arm exports `TF_VAR_cilium_chart_version`, and its exit
status now depends on `wait_for_nodes_ready` through the script it already
calls).

## 6. Implementation steps

1. Add `CILIUM_CHART_VERSION` to `scripts/lib/versions.sh` and its
   `TF_VAR_cilium_chart_version` export to the hetzner `cluster-up` arm.
2. Prove the helm line by hand against a live control plane first, then
   put it into HETZ-030's `templates/control-plane.yaml.tftpl` and
   re-check the render with `terraform console` and `cloud-init schema`.
3. Create a cluster and confirm over SSH that `helm status cilium -n
   kube-system` and `kubectl -n kube-system rollout status ds/cilium`
   are healthy before any worker joins.
4. Write `wait_for_nodes_ready()` and call it after
   `kubeadm_join_workers()`; confirm it returns once both nodes are
   `Ready` and confirm the timeout path by pointing
   `HETZNER_NODE_READY_SECONDS` at a value shorter than the real wait.
5. Run `PROVIDER=hetzner make cluster-up` end to end, record the timing,
   then run it a second time against the same cluster and confirm `helm
   history cilium -n kube-system` still shows one revision.

## 7. Dependencies and blockers

HETZ-030 supplies the control-plane template this spec's helm lines live
in and the `cilium_chart_version` variable they read. HETZ-035 supplies
the joined workers and the kubeconfig this spec's `kubectl` calls use. Nothing in HETZ-045 or HETZ-050 is required first — CoreDNS
staying `Pending` past this spec's own acceptance is the expected
handoff to HETZ-045.

## 8. Acceptance criteria

- Every node reports `Ready` within 10 minutes of `terragrunt apply`
  returning.
- `kubectl -n kube-system rollout status ds/cilium` (or `cilium status
  --wait` where the CLI is available) reports healthy.
- The two-pod cross-node ping in §4 succeeds.
- `kubectl -n kube-system get pods` still shows `coredns` `Pending` —
  documented here as expected, not a regression.
- Allocatable CPU and memory on one `cx33` node, read after Cilium is up,
  are recorded in `research.md`.
- After a second `PROVIDER=hetzner make cluster-up`, `helm history cilium
  -n kube-system` shows exactly one revision — cloud-init runs once per
  server lifetime, so nothing re-runs the install.

## 9. Validation

Offline: `shellcheck` on `scripts/hetzner-bootstrap.sh`; `bash -n`. Real
cloud: the acceptance run in §6/§8, against the HETZ-035 servers already
billed for that spec's own validation.

## 10. AWS regression protection

The aws and civo arms of the `cluster-up` Make target and
`scripts/lib/provider.sh` stay textually unchanged beyond what HETZ-035
already touched. `make -n cluster-up` for `PROVIDER=aws` and
`PROVIDER=civo` is identical to the recorded pre-change output.

## 11. Rollout and rollback/recovery

`PROVIDER=hetzner make cluster-down` destroys the servers; there is no
separate Cilium state to roll back outside the cluster itself. A
`wait_for_nodes_ready()` timeout leaves the cluster joined but not fully
scheduling, and re-running `scripts/hetzner-bootstrap.sh` is safe but does
not repair Cilium: the install lives in a cloud-init that has already run.
The repair is either one `helm upgrade --install` by hand on the control
plane, which the operator reaches with `make node-ssh`, or
`cluster-down`/`cluster-up` for a clean boot.

## 12. Risks and unresolved questions

- Cilium 1.20.2's documented compatibility list stops at 1.36; bump
  `CILIUM_CHART_VERSION` together with the 1.37 upgrade runbook
  (HETZ-185).
- A pod CIDR change after this point is a full cluster re-init, not an
  in-place Cilium reconfigure — `networking.podSubnet` is fixed at
  `kubeadm init` (HETZ-030).
- A Cilium value or version change ships only through `make down` then
  `make up`: the values live in a template that HETZ-030 holds in
  `ignore_changes`, so an edit alone changes nothing on a running
  cluster, and cloud-init never re-runs on an existing server.
- `operator.replicas=1` on a 2-node cluster is a single point of failure
  for IPAM allocation (not the datapath, which the DaemonSet carries);
  accepted at this node count.
- MTU is auto-detected from the private NIC; a Hetzner-side NIC change
  would need re-verifying, not a chart flag change.
- Native routing (Cilium PR #48615) drops the VXLAN encapsulation
  overhead but needs `ipv4NativeRoutingCIDR` pinned to the pod CIDR and
  care with reverse-path filtering; deferred past M1.
  https://github.com/cilium/cilium/pull/48615

## 13. Definition of done

- [ ] Acceptance criteria met on a real cycle with timings recorded
- [ ] `shellcheck` shows no new warnings
- [ ] AWS and Civo `make -n` identity recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); takes the readiness
  wait of the old HETZ-040.
- 2026-09-20 — option C: the install moves from `install_cilium()` in the
  bootstrap script into the control plane's cloud-init (HETZ-030); this
  spec keeps the values, the version pin and the readiness wait
  (decisions.md §3, "Bootstrap driver").
