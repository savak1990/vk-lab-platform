---
id: "HETZ-037"
title: "Cilium CNI from the bootstrap script; cluster-up ends on node Ready"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "One helm release with fixed values and a bounded wait; the judgement is in the connectivity test"
effort_estimate: "Half a session (2–3 h) plus waits"
estimate_confidence: "medium"
depends_on: ["HETZ-035"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-19"
completed: ""
---

# HETZ-037 — Cilium CNI

## 1. Outcome and rationale

Right after `scripts/hetzner-bootstrap.sh`'s `kubeadm_join_workers()`
returns, the same script installs Cilium and then waits until every node
reports `Ready`. kubeadm ships no CNI — this is the exam's own "install a
Pod network add-on" step — so without it every node stays `NotReady` and
nothing schedules. `PROVIDER=hetzner make cluster-up` succeeds only once
every node is `Ready`; a timed-out wait fails the recipe.

## 2. Scope and non-goals

In scope: `install_cilium()` and `wait_for_nodes_ready()` in
`scripts/hetzner-bootstrap.sh`, `scripts/lib/versions.sh`'s
`CILIUM_CHART_VERSION`, and the hetzner arm of the `cluster-up` Make
target insofar as its exit status now depends on `wait_for_nodes_ready`.
Not in scope: the cloud controller manager and CSI driver (HETZ-045,
HETZ-050) — CoreDNS staying `Pending` after this spec's work is their
concern, not this one's; the connectivity test's pod manifests exist only
as a one-off check in §8, not as a committed file; the autoscaler join
path (HETZ-170); native routing mode (§12).

## 3. Current state / evidence

- HETZ-035's `kubeadm_join_workers()` leaves every node joined but
  `NotReady`, carrying `node.cloudprovider.kubernetes.io/uninitialized`;
  its own `wait_for_api()` polls `/readyz` only, deliberately not `Ready`
  nodes, because no CNI exists at that point. HETZ-035 also fixes the
  kubeconfig contract this spec reuses unchanged: `admin.conf` fetched
  into the isolated kubeconfig (ADR 0034), context
  `${PROJECT_NAME}-hetzner`.
- Cilium 1.20.2's default datapath is VXLAN (8472/UDP), needing no CCM
  route programming; `ipam.mode=kubernetes` is required because Cilium's
  own cluster-pool default (`10.0.0.0/8`) collides with the hcloud private
  network, while kubeadm's `networking.podSubnet` (`10.244.0.0/16`, set by
  HETZ-035) is collision-free.
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

Both functions live in `scripts/hetzner-bootstrap.sh`, called in order
right after `kubeadm_join_workers()` returns:

- `install_cilium()`: skips when `helm status cilium -n kube-system`
  already succeeds, printing "already installed" — the same idempotence
  shape HETZ-035 uses for `kubeadm_init` and `kubeadm_join_workers`, and
  what keeps a re-run of `argo-up` from reinstalling the release.
  Otherwise: `helm repo add cilium https://helm.cilium.io` (itself
  idempotent), then
  `helm upgrade --install cilium cilium/cilium --version
  "$CILIUM_CHART_VERSION" -n kube-system --set ipam.mode=kubernetes --set
  routingMode=tunnel --set tunnelProtocol=vxlan --set
  kubeProxyReplacement=false --set operator.replicas=1 --wait --timeout
  5m`. No `k8sServiceHost`/`k8sServicePort` value is set — that pair only
  matters when Cilium replaces kube-proxy, which `kubeProxyReplacement=false`
  does not do here. The release sits outside Argo CD's tree, the same
  untracked-helm-release shape as Argo CD itself and the coming CCM
  (decisions.md §3).
- `wait_for_nodes_ready()`: polls `kubectl get nodes` every 10 s until
  every node's `Ready` condition is `True`, bounded by
  `HETZNER_NODE_READY_SECONDS` (default 600), matching the
  `HETZNER_*`-prefixed env-var style HETZ-035 and HETZ-040 use. On
  timeout it prints the full node list and `kubectl -n kube-system get
  pods`, then exits 1 — giving the operator the CNI DaemonSet's own state
  without a second manual command.
- `CILIUM_CHART_VERSION=1.20.2` is added to `scripts/lib/versions.sh`
  alongside `KUBERNETES_VERSION`.
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

`scripts/hetzner-bootstrap.sh` (adds `install_cilium()`,
`wait_for_nodes_ready()`, and the call to both after
`kubeadm_join_workers()`); `scripts/lib/versions.sh`
(`CILIUM_CHART_VERSION`); `Makefile` (no new target; the hetzner
`cluster-up` arm's exit status now depends on `wait_for_nodes_ready`
through the script it already calls).

## 6. Implementation steps

1. Add `CILIUM_CHART_VERSION` to `scripts/lib/versions.sh`.
2. Write `install_cilium()`; run it by hand against a live HETZ-035
   cluster and confirm `kubectl -n kube-system rollout status
   ds/cilium`.
3. Write `wait_for_nodes_ready()`; confirm it returns once both nodes are
   `Ready` and confirm the timeout path by pointing
   `HETZNER_NODE_READY_SECONDS` at a value shorter than the real wait.
4. Wire both calls after `kubeadm_join_workers()` in
   `scripts/hetzner-bootstrap.sh`; run `PROVIDER=hetzner make cluster-up`
   end to end and record the timing.
5. Run `cluster-up` a second time against the same cluster; confirm
   `helm status cilium` short-circuits `install_cilium()` and `helm
   history cilium -n kube-system` still shows one revision.

## 7. Dependencies and blockers

HETZ-035 supplies joined-but-`NotReady` nodes, the kubeconfig this
spec's `kubectl` calls use, and the idempotence pattern this spec
follows. Nothing in HETZ-045 or HETZ-050 is required first — CoreDNS
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
- After a second `PROVIDER=hetzner make cluster-up`, `helm history
  cilium -n kube-system` shows exactly one revision.

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

`PROVIDER=hetzner make cluster-down` destroys the servers this script
ran against; there is no separate Cilium state to roll back outside the
cluster itself. A failed `install_cilium()` or a `wait_for_nodes_ready()`
timeout leaves the cluster joined but not fully scheduling; re-running
`scripts/hetzner-bootstrap.sh` is safe, because `install_cilium()`'s
`helm status` check and `helm upgrade --install`'s own idempotence mean
the second run repairs or no-ops rather than duplicating the release.

## 12. Risks and unresolved questions

- Cilium 1.20.2's documented compatibility list stops at 1.36; bump
  `CILIUM_CHART_VERSION` together with the 1.37 upgrade runbook
  (HETZ-185).
- A pod CIDR change after this point is a full cluster re-init, not an
  in-place Cilium reconfigure — `networking.podSubnet` is fixed at
  `kubeadm init` (HETZ-035).
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
