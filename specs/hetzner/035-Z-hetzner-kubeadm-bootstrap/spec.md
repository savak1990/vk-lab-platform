---
id: "HETZ-035"
title: "kubeadm join over SSH from cluster-up, admin.conf kubeconfig, idempotent re-run"
status: "SUPERSEDED"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Join configuration, SSH orchestration and idempotence interact; a wrong flag is invisible until the CCM stage"
effort_estimate: "One session (4–6 h) plus boot waits"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-040", "HETZ-020"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-20"
completed: ""
---

# HETZ-035 — kubeadm bootstrap

## 1. Outcome and rationale

The control plane initializes itself at first boot, from its own
cloud-init (HETZ-030): `kubeadm init` and the Cilium install have already
run by the time an operator sees a prompt. The hetzner arm of `cluster-up`
then runs `scripts/hetzner-bootstrap.sh`, which waits for the control
plane's `/var/lib/lab/cp-bootstrap-done` marker, fetches `admin.conf` into
the isolated kubeconfig (ADR 0034), and runs `kubeadm join` on every
worker over SSH. No secret travels through `user_data` to make this work:
kubeadm mints the token on the control plane at join time. Every node
keeps the `node.cloudprovider.kubernetes.io/uninitialized` taint until
HETZ-045's cloud controller manager runs. Re-running the script against an
already-joined cluster is a no-op. This is still the CKA path: `kubeadm
token create`, `kubeadm join` and the kubeconfig handling are all commands
the exam asks for.

## 2. Scope and non-goals

In scope: `scripts/hetzner-bootstrap.sh` and its functions
(`wait_for_control_plane`, `kubeadm_join_workers`, `wait_for_api`), the
hetzner arm of `configure_kubeconfig` in `scripts/lib/provider.sh`, the
`cluster-up` and `kubeconfig` Make arms, and `scripts/lib/versions.sh`'s
`KUBERNETES_VERSION`. Not in scope: `kubeadm init`, the kubeadm config
document and the Cilium install, which are HETZ-030's control-plane
cloud-init; the Cilium values and the node readiness wait (HETZ-037); the
cloud controller manager and CSI (HETZ-045, HETZ-050); the cluster
autoscaler join path (HETZ-170); and `hetzner_ssh`, `cluster_exists` and
`hcloud_list` themselves, which HETZ-040 owns.

## 3. Current state / evidence

- HETZ-030 creates `${project}-cp-1` and `${project}-worker-1` (`cx33`,
  the control plane at private IP `10.0.1.10`, workers from `10.0.1.11`),
  labels every server `role=control-plane|worker`, and writes SSM
  `/${project}/cluster-hetzner/k8s/control_plane_ip`,
  `control_plane_private_ip`, `worker_ips` and `server_ids`. Worker
  cloud-init installs `containerd.io`, `kubeadm`, `kubelet`, `kubectl` and
  the kernel prerequisites only. The control plane's cloud-init also
  renders `/root/kubeadm-config.yaml`, runs `kubeadm init --config …`,
  installs Cilium and touches
  `/var/lib/lab/cp-bootstrap-done`; no token, CA or kubeconfig is in
  `user_data` or Terraform state. `scripts/lib/versions.sh` carries
  `KUBERNETES_VERSION` (1.36.x).
- HETZ-040 supplies `hetzner_ssh <ip> <cmd...>` (decrypts the SSH key into
  a temp dir with a trap, `StrictHostKeyChecking=accept-new`) and
  `hcloud_list`, and defines `cluster_exists()` as two-part: the control
  plane server carries label `role=control-plane` **and** SSH to it shows
  `/etc/kubernetes/admin.conf` present. Since HETZ-030's control plane
  initializes itself, that file appears about two minutes after create,
  without this script running — so `cluster_exists()` reports a cluster
  as soon as the control plane is up, and this spec's idempotence rests on
  the per-worker `/etc/kubernetes/kubelet.conf` check, not on the control
  plane's.
- ADR 0034 (isolated kubeconfig for lifecycle scripts): lifecycle scripts
  write the lab cluster into a repo-local `.kube/${PROJECT_NAME}.config`
  selected through `KUBECONFIG`, never `~/.kube/config`; `configure_kubeconfig
  [path]` is the shared entry point, and an optional path argument lets a
  caller (`kubeconfig` Make target, `argo-state.sh`) choose a different
  target file. A failed fetch aborts rather than writing a partial file.
  `cluster_exists()` asks the provider, never the kubeconfig file's
  presence.
- kubeadm config API v1beta4 for an external cloud provider:
  `nodeRegistration.kubeletExtraArgs` carries
  `[{name: cloud-provider, value: external}, {name: node-ip, value:
  <ip>}]` on `InitConfiguration` and every `JoinConfiguration`;
  `apiServer.certSANs` carries the public IP; `controlPlaneEndpoint` is
  immutable after `kubeadm init`.
  https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/ ;
  https://kubernetes.io/docs/tasks/administer-cluster/running-cloud-controller/
  ; https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- A worker joined without `cloud-provider=external` never receives a
  `providerID` from the CCM (hcloud-cloud-controller-manager issue #267);
  the CCM's node lookup falls back to matching the node's hostname against
  the Hetzner server name, so `nodeRegistration.name` must equal the
  server name on both `init` and every `join`.
  https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/hcloud/instances.go
- kubeadm's own CoreDNS deployment tolerates `CriticalAddonsOnly` and the
  control-plane taint only, not `uninitialized`; CoreDNS therefore stays
  `Pending` until HETZ-045's CCM clears the taint, which is expected here
  and not a bootstrap failure.
  https://github.com/kubernetes/kubernetes/blob/master/cmd/kubeadm/app/phases/addons/dns/manifests.go
- Bootstrap tokens default to a 24 h TTL; `kubeadm token create
  --print-join-command` mints one at join time.
  https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/ ;
  https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/
- decisions.md §3, Control-plane topology: one control plane with stacked
  etcd plus one worker; `controlPlaneEndpoint` is the Terraform-assigned
  private IP `10.0.1.10:6443`, immutable after init but the cluster is
  disposable, so an HA topology changes it on a later `make down`/`up`;
  `control_plane_count > 1` is rejected here until that spec exists.

## 4. Design and contracts

`scripts/hetzner-bootstrap.sh`, sourced by the hetzner arm of
`cluster-up`, after HETZ-030's `terragrunt apply` returns. The functions
run in this order:

- `wait_for_control_plane()` is one SSH call, not a local poll loop:
  `hetzner_ssh <cp> 'for i in $(seq 1 60); do test -f
  /var/lib/lab/cp-bootstrap-done && exit 0; sleep 10; done; exit 1'`. The
  loop count is `HETZNER_CP_BOOTSTRAP_SECONDS` (default 600) divided by
  the 10 s sleep, so the budget is unchanged while the SSH key is
  decrypted once and exactly one temp dir exists for the whole wait. SSH
  may be refused for the first seconds after create, so the call itself is
  retried until it connects, which is not an error while the budget lasts;
  every other poll this script runs over SSH takes the same shape, the
  loop on the remote side. On timeout it prints `cloud-init status
  --long`, `tail -n 50 /var/log/cloud-init-output.log`, `journalctl -u
  cloud-final --no-pager -n 50` and the last 50 lines of `journalctl -u
  kubelet` from the control plane, then exits 1 — a boot-time `kubeadm
  init` failure, and a helm download that fails after a successful init,
  are both invisible to Terraform, so this is where the operator gets the
  evidence without a second manual command.
- `configure_kubeconfig([path])`, hetzner arm: `hetzner_ssh <cp> cat
  /etc/kubernetes/admin.conf`; rewrite `https://10.0.1.10:6443` to
  `https://<control_plane_ip>:6443`; rename the context, cluster and user
  to `${PROJECT_NAME}-hetzner`; merge into the target (default per ADR
  0034, or the caller's `path`) with `kubectl config view --flatten`. The
  `kubeconfig` Make arm and `argo-state.sh` both call this with no other
  path logic of their own.
- `kubeadm_join_workers()` rejects up front when `control_plane_count > 1`
  with "HA control plane needs a stable controlPlaneEndpoint; see
  decisions.md". Otherwise, for each IP in SSM `worker_ips`: skip when
  `hetzner_ssh <worker> test -f /etc/kubernetes/kubelet.conf` succeeds;
  otherwise `JOIN=$(hetzner_ssh <cp> kubeadm token create
  --print-join-command)` and write `/root/kubeadm-join.yaml` on the worker
  with the `discovery.bootstrapToken` fields parsed out of `$JOIN`, plus
  `nodeRegistration.name=<worker server name>`,
  `nodeRegistration.kubeletExtraArgs` `cloud-provider=external` and
  `node-ip=<worker private ip>`. The join config carries no
  `KubeletConfiguration`: the reservations come from the cluster's
  `kubelet-config` ConfigMap, written at `kubeadm init` (HETZ-030) and
  downloaded by every join. Then run `kubeadm join --config
  /root/kubeadm-join.yaml` on the worker over SSH. Never prints `$JOIN` or
  any other `kubeadm token` output to the script's own stdout; under
  `GITHUB_ACTIONS` that output is masked like every other secret.
- `wait_for_api()` polls `kubectl get --raw /readyz` against the fetched
  kubeconfig every 10 s for up to 5 min, then returns. It deliberately
  stops at the API server: a freshly joined worker needs a further minute
  or two before its kubelet reports `Ready`, and HETZ-037's
  `wait_for_nodes_ready()` owns that wait.
- Idempotence: a second `scripts/hetzner-bootstrap.sh` run against an
  already-joined cluster performs zero `kubeadm` calls —
  `wait_for_control_plane()` finds the marker on its first poll and every
  worker's join loop iteration prints "already joined" and returns. The
  control plane's own cloud-init runs once per server lifetime, so nothing
  re-initializes it.

## 5. Files/components affected

`scripts/hetzner-bootstrap.sh` (new); `scripts/lib/provider.sh` (the
hetzner arm of `configure_kubeconfig`); `scripts/lib/argo-state.sh` (calls
`configure_kubeconfig`, unchanged call shape); `Makefile` (the hetzner arm
of `cluster-up` calls `scripts/hetzner-bootstrap.sh` after `apply`; the
`kubeconfig` arm); `scripts/lib/versions.sh` (`KUBERNETES_VERSION`, already
present from HETZ-030).

## 6. Implementation steps

1. Write `wait_for_control_plane()`; run it against a freshly created
   HETZ-030 control plane, record the create-to-marker time, and force the
   timeout path with a short `HETZNER_CP_BOOTSTRAP_SECONDS` to confirm it
   prints all four diagnostic commands §4 lists.
2. Write `configure_kubeconfig`'s hetzner arm and the `cluster-up` /
   `kubeconfig` Make arms; run `make kubeconfig` from the operator machine
   and confirm `kubectl get nodes` lists the control plane.
3. Write `kubeadm_join_workers()` and `wait_for_api()`; join the one
   worker and confirm `kubectl get nodes` lists both servers.
4. Run `scripts/hetzner-bootstrap.sh` a second time against the same
   cluster; confirm zero `kubeadm` calls.
5. Two full `cluster-up` cycles end to end (HETZ-030's apply through this
   script), recording timings for each.

## 7. Dependencies and blockers

HETZ-030 supplies the servers, their names, private IPs and SSM outputs,
and the control plane that has already initialized itself and installed
Cilium by first boot. HETZ-040 supplies `hetzner_ssh`,
`cluster_exists` and `hcloud_list`, which this script calls but does not
define. HETZ-020's feasibility spike recorded the init → Cilium → CCM → CoreDNS
ordering this spec assumes without re-proving it; under option C the first
two steps happen at boot rather than from this script, which does not
change the ordering.

## 8. Acceptance criteria

- `kubectl get nodes` lists `control_plane_count + worker_count` nodes.
  The control plane is `Ready` when the script starts, because its own
  cloud-init installed Cilium (HETZ-030); the workers reach `Ready` after
  HETZ-037's wait. Every node still carries
  `node.cloudprovider.kubernetes.io/uninitialized`, and `kubectl get pods
  -n kube-system` shows `coredns` `Pending` until HETZ-045's cloud
  controller manager clears that taint.
- `kubectl get --raw /readyz` returns `ok`.
- A second `cluster-up` run makes zero `kubeadm` calls.
- `make kubeconfig` writes context `${PROJECT_NAME}-hetzner`.
- `kubeadm certs check-expiration` runs cleanly on the control plane.
- `terraform state pull` for `cluster-hetzner/k8s` is unchanged from
  HETZ-030's baseline — no cluster data ever enters Terraform state.

## 9. Validation

Offline: `shellcheck` on `scripts/hetzner-bootstrap.sh`; `bash -n`. Real
cloud: the two-cycle acceptance run in §6, against the HETZ-030 servers
already billed for that spec's own validation.

## 10. AWS regression protection

`scripts/lib/provider.sh`'s aws and civo arms of `configure_kubeconfig`,
and `scripts/lib/argo-state.sh`, stay textually unchanged beyond the
hetzner branch this spec adds. `make -n cluster-up` and `make -n
kubeconfig` for `PROVIDER=aws` and `PROVIDER=civo` are identical to the
recorded pre-change output.

## 11. Rollout and rollback/recovery

`PROVIDER=hetzner make cluster-down` destroys the servers this script ran
against; there is no cluster state outside them to roll back. A failed
`kubeadm join` leaves a half-joined worker; re-running the script is safe,
because the join is guarded by the worker's own
`/etc/kubernetes/kubelet.conf` check. A control plane whose boot-time
`kubeadm init` failed cannot be repaired by re-running this script — the
recovery is `cluster-down` then `cluster-up`, which boots a fresh server
and runs its cloud-init again.

## 12. Risks and unresolved questions

- A 24 h join-token expiry if a worker joins later than the control
  plane's init; accepted because the token is created at join time, not
  reused from init.
- A worker joined without `cloud-provider=external` never gets a
  `providerID` from the CCM (hccm issue #267); every join, including a
  later autoscaled one, must carry it.
- A node's hostname must equal its Hetzner server name or the CCM's
  fallback lookup fails; `nodeRegistration.name` enforces this here.
- `controlPlaneEndpoint` is immutable once set; an HA control plane needs
  a stable endpoint decided before any `kubeadm init`, which forces a
  re-init on a fresh `make up`, not an in-place change.
- A control-plane reboot takes the API server down for roughly a minute;
  scripts calling this one should not treat a single failed poll as fatal
  without a retry budget.
- A boot-time `kubeadm init` failure is visible only over SSH: Terraform
  reports a healthy `running` server and this script sees a marker that
  never appears. `wait_for_control_plane()`'s timeout path printing
  `cloud-init status --long`, the cloud-init output log, the `cloud-final`
  journal and the kubelet journal is the whole of the diagnosis path, so
  it must not be dropped for brevity.
- `HETZNER_CP_BOOTSTRAP_SECONDS` must stay comfortably above the observed
  create-to-marker time (§6 step 1 records it): image pulls during
  `kubeadm init` dominate it and vary with Hetzner-side network
  conditions.

## 13. Definition of done

- [ ] Acceptance criteria met on two real cycles with timings recorded
- [ ] `shellcheck` shows no new warnings
- [ ] AWS and Civo `make -n` identity recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); takes the
  cluster-creation part of the old HETZ-030 and the kubeconfig part of the
  old HETZ-040.
- 2026-09-20 — option C: `kubeadm init` and the kubeadm config render move
  into the control plane's cloud-init (HETZ-030); this script waits for the
  boot marker, joins the workers and fetches the kubeconfig (decisions.md
  §3, "Bootstrap driver").
- 2026-09-20 — review fixes: the marker wait is one SSH call with the loop
  on the remote side; the join config drops its duplicated
  `KubeletConfiguration` in favour of the cluster's `kubelet-config`
  ConfigMap; the timeout dump gains the cloud-init output log and the
  `cloud-final` journal.
- 2026-09-20 — `SUPERSEDED` by HETZ-017 and ADR 0037. This spec exists only
  because kubeadm needs an out-of-band worker join. Under k3s a worker joins at
  first boot from `K3S_URL` and the Terraform-generated token, so there is no
  join step, no SSH in the create path and no `scripts/hetzner-bootstrap.sh`.
  Two pieces survive and move to HETZ-040: the Hetzner arm of
  `configure_kubeconfig`, now reading `/etc/rancher/k3s/k3s.yaml` and rewriting
  `127.0.0.1` to the public address, and the wait for every node to report
  Ready. Nothing here was implemented.
