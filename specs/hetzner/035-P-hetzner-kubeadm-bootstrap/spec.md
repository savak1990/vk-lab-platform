---
id: "HETZ-035"
title: "kubeadm bootstrap over SSH: init, join, kubeconfig, idempotent re-run"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "kubeadm config, SSH orchestration and idempotence interact; a wrong flag is invisible until the CCM stage"
effort_estimate: "One session (4–6 h) plus boot waits"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-040", "HETZ-020"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-19"
completed: ""
---

# HETZ-035 — kubeadm bootstrap

## 1. Outcome and rationale

After HETZ-030's servers exist, the hetzner arm of `cluster-up` runs
`scripts/hetzner-bootstrap.sh`, which turns them into a kubeadm cluster
over SSH: render the kubeadm config, `kubeadm init` on the control plane,
fetch `admin.conf` into the isolated kubeconfig (ADR 0034), `kubeadm join`
on every worker. Nodes stay `NotReady` with the
`node.cloudprovider.kubernetes.io/uninitialized` taint until HETZ-037
(Cilium) and HETZ-045 (the cloud controller manager) run. Re-running the
script against an already-initialized cluster is a no-op. This is the CKA
path: every command is one the exam asks for.

## 2. Scope and non-goals

In scope: `scripts/hetzner-bootstrap.sh` and its functions
(`render_kubeadm_config`, `kubeadm_init`, `kubeadm_join_workers`,
`wait_for_api`), the hetzner arm of `configure_kubeconfig` in
`scripts/lib/provider.sh`, the `cluster-up` and `kubeconfig` Make arms, and
`scripts/lib/versions.sh`'s `KUBERNETES_VERSION`. Not in scope: the Cilium
install (HETZ-037), the cloud controller manager and CSI (HETZ-045,
HETZ-050), the cluster autoscaler join path (HETZ-170), and `hetzner_ssh`,
`cluster_exists` and `hcloud_list` themselves, which HETZ-040 owns.

## 3. Current state / evidence

- HETZ-030 creates `${project}-cp-1` and `${project}-worker-1` (`cx33`,
  the control plane at private IP `10.0.1.10`, workers from `10.0.1.11`),
  labels every server `role=control-plane|worker`, and writes SSM
  `/${project}/cluster-hetzner/k8s/control_plane_ip`,
  `control_plane_private_ip`, `worker_ips` and `server_ids`. Cloud-init
  installs `containerd.io`, `kubeadm`, `kubelet`, `kubectl` and the kernel
  prerequisites only — no join token, no cluster state, no `kubeadm init`.
  `scripts/lib/versions.sh` carries `KUBERNETES_VERSION` (1.36.x).
- HETZ-040 supplies `hetzner_ssh <ip> <cmd...>` (decrypts the SSH key into
  a temp dir with a trap, `StrictHostKeyChecking=accept-new`) and
  `hcloud_list`, and defines `cluster_exists()` as two-part: the control
  plane server carries label `role=control-plane` **and** SSH to it shows
  `/etc/kubernetes/admin.conf` present. A server that exists but was never
  initialized therefore does not read as a cluster, which this spec's
  idempotence check depends on.
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
`cluster-up`, after HETZ-030's `terragrunt apply` returns:

- `render_kubeadm_config()` builds one YAML document, piped over SSH
  straight to `/root/kubeadm-config.yaml` on the control plane — never
  written to a temp file on the operator machine, because it holds no
  secret. `InitConfiguration`: `nodeRegistration.name=${project}-cp-1`,
  `nodeRegistration.kubeletExtraArgs` `cloud-provider=external` and
  `node-ip=10.0.1.10`, `nodeRegistration.taints: []` (keeps the control
  plane schedulable), `localAPIEndpoint.advertiseAddress=10.0.1.10`.
  `ClusterConfiguration`: `kubernetesVersion` from `KUBERNETES_VERSION`,
  `controlPlaneEndpoint="10.0.1.10:6443"`, `networking.podSubnet
  10.244.0.0/16`, `networking.serviceSubnet 10.96.0.0/12`,
  `apiServer.certSANs=[<control_plane_ip>]`,
  `controllerManager.extraArgs bind-address=10.0.1.10`,
  `scheduler.extraArgs bind-address=10.0.1.10`,
  `etcd.local.extraArgs listen-metrics-urls=http://10.0.1.10:2381`.
  `KubeletConfiguration`: `cgroupDriver: systemd`.
  `KubeProxyConfiguration`: `metricsBindAddress: 10.0.1.10:10249`.
- `kubeadm_init()` skips when `hetzner_ssh <cp> test -f
  /etc/kubernetes/admin.conf` succeeds and prints "already initialized";
  otherwise runs `hetzner_ssh <cp> kubeadm init --config
  /root/kubeadm-config.yaml --upload-certs` and aborts the whole script on
  a non-zero exit.
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
  `nodeRegistration.name=<worker server name>` and
  `nodeRegistration.kubeletExtraArgs` `cloud-provider=external` and
  `node-ip=<worker private ip>`; run `kubeadm join --config
  /root/kubeadm-join.yaml` on the worker over SSH. Never prints `$JOIN` or
  any other `kubeadm token` output to the script's own stdout; under
  `GITHUB_ACTIONS` that output is masked like every other secret.
- `wait_for_api()` polls `kubectl get --raw /readyz` against the fetched
  kubeconfig every 10 s for up to 5 min, then returns; it does not wait for
  `Ready` nodes, because no CNI exists yet at this stage (HETZ-037).
- Idempotence: a second `scripts/hetzner-bootstrap.sh` run against an
  already-initialized, already-joined cluster performs zero `kubeadm`
  calls — `kubeadm_init` and every worker's join loop iteration print
  "already initialized" / "already joined" and return.

## 5. Files/components affected

`scripts/hetzner-bootstrap.sh` (new); `scripts/lib/provider.sh` (the
hetzner arm of `configure_kubeconfig`); `scripts/lib/argo-state.sh` (calls
`configure_kubeconfig`, unchanged call shape); `Makefile` (the hetzner arm
of `cluster-up` calls `scripts/hetzner-bootstrap.sh` after `apply`; the
`kubeconfig` arm); `scripts/lib/versions.sh` (`KUBERNETES_VERSION`, already
present from HETZ-030).

## 6. Implementation steps

1. Write `render_kubeadm_config()` and `kubeadm_init()`; run both by hand
   against a live HETZ-030 cluster over SSH and confirm `kubectl get
   --raw /readyz` from the control plane.
2. Write `kubeadm_join_workers()`; join the one worker and confirm
   `kubectl get nodes` lists both servers, `NotReady`.
3. Write `configure_kubeconfig`'s hetzner arm and the `cluster-up` /
   `kubeconfig` Make arms; run `make kubeconfig` from the operator machine.
4. Run `scripts/hetzner-bootstrap.sh` a second time against the same
   cluster; confirm zero `kubeadm` calls.
5. Two full `cluster-up` cycles end to end (HETZ-030's apply through this
   script), recording timings for each.

## 7. Dependencies and blockers

HETZ-030 supplies the initialized-but-clusterless servers, their names,
private IPs and SSM outputs. HETZ-040 supplies `hetzner_ssh`,
`cluster_exists` and `hcloud_list`, which this script calls but does not
define. HETZ-020's feasibility spike recorded the init → Cilium → CCM →
CoreDNS ordering this spec assumes without re-proving it.

## 8. Acceptance criteria

- `kubectl get nodes` lists `control_plane_count + worker_count` nodes,
  all `NotReady`, all carrying
  `node.cloudprovider.kubernetes.io/uninitialized`.
- `kubectl get pods -n kube-system` shows `etcd`, `kube-apiserver`,
  `kube-controller-manager` and `kube-scheduler` `Running`, and `coredns`
  `Pending`.
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
`kubeadm init` or `join` leaves a partially initialized server; re-running
the script is safe because every step is guarded by the same file-presence
check `cluster_exists()` uses.

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

## 13. Definition of done

- [ ] Acceptance criteria met on two real cycles with timings recorded
- [ ] `shellcheck` shows no new warnings
- [ ] AWS and Civo `make -n` identity recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); takes the
  cluster-creation part of the old HETZ-030 and the kubeconfig part of the
  old HETZ-040.
