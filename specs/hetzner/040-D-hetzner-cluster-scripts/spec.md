---
id: "HETZ-040"
title: "Cluster scripts for Hetzner: hcloud helpers, SSH helper, kubeconfig fetch, node-Ready wait, existence proof, node-ssh, label-based leak sweep"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Shell branches with clear specifications; SSH key hygiene and the leak sweep must be correct but the logic is simple"
effort_estimate: "One session (4–6 h) including one real cluster-up/cluster-down cycle"
estimate_confidence: "medium"
depends_on: ["HETZ-017", "HETZ-030"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-22"
completed: "2026-09-22"
---

# HETZ-040 — Cluster scripts for Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up`, `cluster-down`, `status` and
`kubeconfig` work on Hetzner, and the helpers every later Hetzner script
needs exist in one place: `hcloud_token`, `hcloud_cli`, `hcloud_list_names`,
`hetzner_ssh`, `cluster_exists`, `configure_kubeconfig`.

Hetzner returns no kubeconfig from any API, so the scripts fetch k3s's own
over SSH and rewrite its address. Terraform returns when servers boot, not
when a cluster exists, so `cluster-up` ends by waiting until every node
reports Ready, and existence is proved in two parts: the control-plane
server carries the label, and `/etc/rancher/k3s/k3s.yaml` exists on it.
Nothing here creates the cluster — every node installs k3s from its own
cloud-init (HETZ-030). These scripts observe it and clean it up. The leak
sweep selects
resources by label, because load balancers, volumes and primary IPs
outlive the servers on Hetzner, and it removes autoscaled servers before
Terraform destroys the fixed ones. A new `make node-ssh` target opens a
shell on one node; on the other providers it prints a message and exits 0.

## 2. Scope and non-goals

In scope: the hetzner arms of `scripts/lib/provider.sh` (`hcloud_token`,
`hcloud_cli`, `hcloud_list_names`, `hetzner_ssh`, `cluster_exists`,
`configure_kubeconfig`), the `wait_for_nodes_ready` gate at the end of the
hetzner `cluster-up` arm, `scripts/cluster-down.sh` (pre-destroy and
post-destroy sweeps), `scripts/status.sh`, `scripts/lib/argo-state.sh`,
`scripts/require-persistent.sh`, the guard lists, the `Makefile` targets
`cluster-up`, `cluster-down`, `status`, `kubeconfig`, `node-ssh`. Not in
scope: `configure_test_kubeconfig` (HETZ-130); the cloud controller
manager and the `uninitialized` taint wait (HETZ-045);
`argo-up`/`argo-down` (HETZ-045, HETZ-047); the autoscaler itself
(HETZ-170) beyond the sweep that removes its servers.

## 3. Current state / evidence

- `scripts/lib/provider.sh:169-187` proves cluster existence (`civo kubernetes show` at `:173`); `:288-315` fetches the kubeconfig with `civo kubernetes config` and renames the context to `${PROJECT_NAME}-civo` using the bash-3.2-safe `${kcfg[@]:+"${kcfg[@]}"}` idiom.
- `scripts/cluster-down.sh:51-95` sweeps Civo resources by name with `civo_list_names`. It can only report a leaked LB, because the civo CLI has no delete verb for it.
- `scripts/status.sh:59-61` reads `cluster_name` from `terraform/live/cluster-civo/k8s`.
- `Makefile:214-217` calls `civo_token` before the terragrunt apply; `:259-260` is the `kubeconfig` target, already provider-generic.
- HETZ-030 creates `${project}-cp-1` and `${project}-worker-1`, labels every server `project=${project}`, `scope=platform`, `lifecycle=disposable`, `managed_by=terraform`, `role=control-plane|worker`, and writes `/${project}/cluster-hetzner/k8s/{control_plane_ip,control_plane_private_ip,worker_ips,server_ids}` to SSM. Each server installs k3s from its own cloud-init: the control plane as `k3s server` with embedded etcd, the worker as `k3s agent` against `https://10.0.1.10:6443`. Both are running a minute or two after create, with no step from any script. HETZ-025 commits the SSH public key and `secrets/<project>/hetzner-ssh-key.enc`.
- `/etc/rancher/k3s/k3s.yaml` on the control plane is the durable sign that the cluster exists, and k3s writes it at mode 0600 with the server address `https://127.0.0.1:6443`. https://docs.k3s.io/cluster-access
- HETZ-170's autoscaler creates servers Terraform does not know, labelled `managed_by=autoscaler`. They boot the same worker cloud-init and join the same way, so nothing here treats them differently except the sweep.
- `hcloud` CLI v1.68.0 (verified 2026-09-19) is stateless when `HCLOUD_TOKEN` is set; it writes no file unless `hcloud context create` runs (research.md).

## 4. Design and contracts

- `hcloud_token()` decrypts `hetzner-token` (`SECRET_SCOPE=global`), masks it under `GITHUB_ACTIONS`, exports `HCLOUD_TOKEN`. `hcloud_cli()` runs `hcloud "$@"` with `HCLOUD_CONFIG=/dev/null`, so no context file is ever written - the same guarantee an empty `mktemp` would give, without a file to clean up afterwards. `hcloud_list_names(resource, [label terms...])` runs `hcloud <resource> list -l project=${PROJECT_NAME}[,terms] -o json` and prints names; the project label is always implied, and an empty list prints nothing.
- `hetzner_ssh(ip, cmd...)`: decrypts `hetzner-ssh-key` into a `mktemp -d` directory as a mode-0600 file; `trap 'rm -rf "$dir"' EXIT INT TERM`; runs `ssh -i "$dir/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$dir/known_hosts" -o ConnectTimeout=10 root@<ip> "$@"` and returns its exit status. One KMS decrypt and one temp dir per call: a caller that needs to poll runs the loop on the remote side inside a single call, never `hetzner_ssh` in a local loop. `cluster_exists`, `configure_kubeconfig`, the readiness wait and `node-ssh` all use it. Nothing prints the key.
- `cluster_exists()` on hetzner is two-part: `hcloud_list_names server role=control-plane` is non-empty AND `hetzner_ssh <cp ip> test -f /etc/rancher/k3s/k3s.yaml` succeeds, with the cp IP from SSM `/${PROJECT_NAME}/cluster-hetzner/k8s/control_plane_ip`. It answers one question only — does a cluster exist — and it is true from the moment the control plane finishes booting. A server whose boot-time k3s install failed still returns false.
- `configure_kubeconfig([path])` on hetzner: read the control-plane public IP from SSM; `hetzner_ssh <ip> <wait for and cat /etc/rancher/k3s/k3s.yaml>`, the wait bounded by `HETZNER_K3S_WAIT_SECONDS` (default 180) and running on the remote side so the one-decrypt-per-call rule holds; rewrite `https://127.0.0.1:6443` to `https://<ip>:6443`; rename the context, cluster and user to `${PROJECT_NAME}-hetzner`, deleting a stale context of that name first so a re-run is clean; merge into the target with `KUBECONFIG=<target>:<tmp> kubectl config view --flatten`, then the shared `kubectl config set-context --current --namespace=default` tail. It writes only to the isolated kubeconfig unless `make kubeconfig` names another (constitution §17, ADR 0034), keeps the bash-3.2-safe `${kcfg[@]:+"${kcfg[@]}"}` idiom the civo arm uses, and returns 1 on any failure because callers use `|| return 1`. The fetched file carries cluster credentials and is never echoed. `hetzner_kubeconfig` (`provider.sh:238-286`) already did this before HETZ-040. What changes: it fetches through `hetzner_ssh`, so the decrypted key is trapped, and it deletes a stale context, cluster and user of the same name before the flatten merge - the first file to set a name wins that merge, so an entry from an earlier cluster would otherwise shadow the new one and keep its dead address.
- `wait_for_nodes_ready()` runs at the end of the hetzner `cluster-up` arm, after `configure_kubeconfig`: poll until `kubectl get nodes` lists `control_plane_count + worker_count` nodes and every one reports `Ready`, bounded by `HETZNER_NODE_READY_SECONDS` (default 600) with `ARGO_UP_POLL_INTERVAL` between polls. Every node still carries `node.cloudprovider.kubernetes.io/uninitialized` and CoreDNS is still `Pending` at this point — HETZ-045's cloud controller manager clears the taint — so the gate asserts Ready only, never Schedulable. On timeout it prints the node list and, for each node that never registered, `cloud-init status --long`, `tail -n 50 /var/log/cloud-init-output.log` and `journalctl -u k3s` or `journalctl -u k3s-agent`, each as one remote command.
- The Argo guard in `cluster-down` is a separate, later check, not a consequence of `cluster_exists`. Three cases: no control-plane server, so `cluster_exists` is false and the script destroys directly; a cluster with no Argo CD on it, where the script fetches the kubeconfig and asks for the `root` Application, reads `no matches for kind` or `not found`, and destroys directly; and a cluster with a `root` Application actually present, which is the only case that refuses. A missing CRD or a missing object must never be treated as a failed query.
- Host-key trust: `accept-new` with a per-call known_hosts file trusts the first key seen for that IP. The IP is fresh from Terraform seconds earlier and the API server certificate check follows over TLS, so the window for a MITM is the SSH fetch itself. Pinning is possible through `hcloud server ssh` (same trust model) or by reading the host key from the server console; both are deferred (§12).
- `cluster-down.sh` on hetzner, **before** `terragrunt run --all destroy`: delete every server matching `project=${PROJECT_NAME},managed_by=autoscaler` (`hcloud server delete`) and poll `hcloud_list_names` until none remain (up to 3 min). The autoscaler is gone with the cluster by then (HETZ-047), so nothing recreates them; a server that Terraform never created would otherwise keep its primary IP and any attached volume alive after the fixed nodes are destroyed.
- `cluster-down.sh` on hetzner, after `terragrunt run --all destroy`: sweep by label `project=${PROJECT_NAME}` in this order — load balancers (`hcloud load-balancer delete`), volumes (`hcloud volume detach` then `delete`), servers not created by Terraform (`hcloud server delete`), primary IPs that are unassigned (`hcloud primary-ip delete`), firewalls (`hcloud firewall delete`). Report each deletion. A leaked volume or LB fails the run with exit 1 after the sweep, as on Civo, so a cascade bug surfaces.
- `status.sh` on hetzner does **not** read a `cluster_name` Terraform output: `terraform/modules/hcloud-nodes` publishes none, because k3s has no managed-cluster object to name. `CLUSTER_NAME` is already `$PROJECT_NAME` (`provider.sh:32`), so the branch keeps it and clears it only when SSM holds no `control_plane_ip` - which is what "cluster not up" means on this target. The prefix loop at `:27` already carries `persistent-hetzner cluster-hetzner`. `argo-state.sh` gains a hetzner branch calling `configure_kubeconfig`; `hcloud_token` is not needed, because that fetch goes over SSM and SSH, not the hcloud API.
- `require-persistent.sh` on hetzner skips the `eks-access-identity` check and requires `persistent-hetzner/network` and `persistent-hetzner/ssh-key` state to be non-empty. `bootstrap-down.sh`, `persistent-down.sh` and `state-down.sh` guard lists gain the prefixes `persistent-hetzner` and `cluster-hetzner`.
- `Makefile`: the `cluster-up` hetzner arm calls `hcloud_token`, applies, then `configure_kubeconfig` and `wait_for_nodes_ready`; `cluster-down` calls `hcloud_token` before the script; `kubeconfig` calls `configure_kubeconfig` with the operator's path; `node-ssh` (`NODE` defaults to `${PROJECT_NAME}-cp-1`) resolves the server's public IP with `hcloud_cli server ip "$NODE"` and runs `hetzner_ssh` interactively on hetzner; on aws and civo it prints `node-ssh: not applicable for PROVIDER=<p>` and exits 0.
- CI hygiene: the decrypted key exists only in the temp dir and is removed by the trap; nothing prints it. `GITHUB_ACTIONS` masking applies to the token only.

## 5. Files/components affected

`scripts/lib/provider.sh`, `scripts/cluster-down.sh`, `scripts/status.sh`,
`scripts/lib/argo-state.sh`, `scripts/require-persistent.sh`,
`scripts/bootstrap-down.sh`, `scripts/persistent-down.sh`, `scripts/state-down.sh`
(guard lists gain the two hetzner prefixes), `Makefile` (`cluster-up`,
`cluster-down`, `kubeconfig`, `node-ssh`, `.PHONY`). No Terraform or
GitOps changes.

## 6. Implementation steps

1. Add `hetzner_ssh` and `hetzner_cp_ip`; `hcloud_token`, `hcloud_cli` and `hcloud_list_names` already exist. Test `hcloud_cli` writes no file under `$HOME/.config/hcloud`; test `hetzner_ssh` against a HETZ-030 server and confirm the trap removes the key on Ctrl-C.
2. Add the two-part `cluster_exists`. Test both halves: a server whose k3s install failed, and no servers at all.
3. Add `configure_kubeconfig` and `wait_for_nodes_ready` against a HETZ-030 cluster. Confirm a re-run replaces the context rather than appending a second one, and that the timeout path prints the three diagnostics.
4. Branch `cluster-down.sh`: the pre-destroy autoscaler sweep, then the post-destroy label sweep. Keep the aws and civo paths textually identical.
5. Update the guard lists, `status.sh`, `argo-state.sh`, `require-persistent.sh`, the Makefile arms.
6. Run `PROVIDER=hetzner make cluster-up`, `make kubeconfig`, `make status`, `make node-ssh`, `make cluster-down`. Leave one labelled volume and one hand-made server labelled `managed_by=autoscaler` behind on purpose and confirm the sweeps delete both and the run exits 1 on the volume leak.

## 7. Dependencies and blockers

HETZ-030 supplies the servers, labels, SSM outputs and the SSH public key
binding, and its cloud-init is what makes the cluster exist for these
scripts to find. HETZ-025 supplies the encrypted private key. HETZ-017
supplies the bootstrap decision that moved `configure_kubeconfig` and the
readiness wait into this spec. HETZ-045 consumes `configure_kubeconfig`
and `cluster_exists` and can be drafted in parallel.

## 8. Acceptance criteria

- `PROVIDER=hetzner make cluster-up` exits only after `kubectl get nodes` shows every node `Ready`, within `HETZNER_NODE_READY_SECONDS`; the measured time from `apply` is recorded.
- `make kubeconfig` writes context `${PROJECT_NAME}-hetzner` whose server is the control plane's public IP, and `kubectl get nodes` works from the operator machine. A second run leaves exactly one context of that name.
- On a cluster with no Argo CD, `make cluster-down` finds no `root` Application, destroys without refusing, sweeps a hand-made labelled volume and a hand-made `managed_by=autoscaler` server, and exits 1 because the volume leaked. `hcloud server list`, `load-balancer list`, `volume list`, `primary-ip list` filtered by `project=${PROJECT_NAME}` are all empty afterwards.
- On a cluster with Argo CD installed, `make cluster-down` refuses while a `root` Application exists.
- `cluster_exists` returns false when no control-plane server exists, and false on a control plane whose boot-time k3s install failed.
- With one worker's cloud-init deliberately broken, `cluster-up` fails within the budget and prints that node's `cloud-init status --long` and `journalctl -u k3s-agent` (tested once, then reverted).
- `make node-ssh` opens a root shell on `${PROJECT_NAME}-cp-1` on hetzner and exits 0 with a message on aws and civo.
- `make status` lists the `persistent-hetzner` and `cluster-hetzner` units.
- No script prints the Hetzner token or the SSH private key; the temp dir is gone after every run, including an interrupted one; `$HOME/.config/hcloud` never appears.

## 9. Validation

Offline: `shellcheck` against the CIVO-045 baseline; `bash -n`. Real cloud: one Hetzner cycle (two `cx33` for under an hour, about 0.05 EUR). AWS and Civo: dry runs only.

## 10. AWS regression protection

The aws and civo branches do not change textually beyond the guard-list
additions. Diff `make -n cluster-up`, `make -n cluster-down` and `make -n
status` for `PROVIDER=aws` and `PROVIDER=civo` against the recorded output
before this change: identical. Run `PROVIDER=civo make status` against the
civo project and compare with the recorded baseline.

## 11. Rollout and rollback/recovery

Revert the scripts. There is no data risk. `cluster-down` never touches
the persistent units, because they live in a separate stack directory.

## 12. Risks and unresolved questions

- `accept-new` host-key trust on first contact is a known gap. Mitigation candidates: read the host key fingerprint from the Hetzner console API (not available), or generate the host key in cloud-init from a value Terraform knows (`ssh_keys` is for user keys only). Documented, not solved in M1.
- SSH on port 22 from `0.0.0.0/0` (HETZ-030) is the price of GitHub runners with no fixed IP; key-only auth holds.
- The pre-destroy sweep deletes an autoscaled server while a volume is still attached: detach first, and a volume attached to a server that is already gone reports `available` and is deleted by the post-destroy sweep.
- The `hcloud` CLI version must be pinned in docs and CI (HETZ-140); 1.68.0 verified on 2026-09-19, flag names changed across releases.

## 13. Definition of done

- [x] Acceptance criteria evidence recorded for hetzner
- [x] `make -n` identity for aws and civo recorded
- [x] `shellcheck` shows no new warnings
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — rewritten for kubeadm: kubeconfig and readiness moved to the kubeadm bootstrap and Cilium CNI specs, both since retired; two-part `cluster_exists`; autoscaled servers swept before destroy.
- 2026-09-20 — option C: the control plane initializes itself at boot, so `cluster_exists` is true before the kubeadm bootstrap step runs; the Argo guard is stated as a separate three-case check (decisions.md §3, "Bootstrap driver").
- 2026-09-20 — review fix: `hetzner_ssh` states one KMS decrypt and one temp dir per call, so every poll over SSH loops on the remote side.
- 2026-09-20 — k3s (HETZ-017, ADR 0037). This spec absorbs the two pieces of
  the retired kubeadm bootstrap spec that survive the bootstrap change: the hetzner arm of
  `configure_kubeconfig`, now reading `/etc/rancher/k3s/k3s.yaml` and
  rewriting `127.0.0.1`, and the node-Ready wait, which no longer waits on a
  CNI install because k3s starts flannel itself. `cluster_exists` probes the
  k3s kubeconfig instead of `admin.conf`. The `cluster-up` and `kubeconfig`
  Make arms move here. The sweeps, the guards and the three-case Argo check
  are unchanged.
- 2026-09-21 — implemented; status `IN_REVIEW`, folder renamed to
  `040-A-hetzner-cluster-scripts`. Four contracts in §3 and §4 were stale
  against the tree and are corrected above rather than re-derived during
  implementation: the list helper is `hcloud_list_names` and already existed,
  `hcloud_cli` uses `HCLOUD_CONFIG=/dev/null` rather than an empty `mktemp`,
  the `configure_kubeconfig` stub this spec claimed to replace was already
  implemented, and `status.sh` cannot read a `cluster_name` output that no
  Hetzner module publishes.
- 2026-09-21 — two defects found while implementing, both fixed here rather
  than deferred. `hetzner_kubeconfig` decrypted the SSH private key into an
  untrapped `mktemp`, so `Ctrl-C` between the decrypt and the `rm` left it on
  disk, and it passed no `UserKnownHostsFile`, so it wrote `accept-new`
  entries into the operator's own `~/.ssh/known_hosts`. Routing it through
  `hetzner_ssh` fixes both. Separately, the flatten merge takes the first
  file's entry for a given name, so a re-created cluster kept the previous
  server address; the stale context, cluster and user are now deleted first.
- 2026-09-21 — third defect, found in review before the live run: `cluster-up`
  chains `configure_kubeconfig` straight after `terragrunt apply`, but apply
  returns when the servers are running and cloud-init needs another minute or
  two to install k3s. A bare `cat` would have failed on a healthy cluster and
  killed the chain before `wait_for_nodes_ready` could report anything. The
  fetch now waits for the file on the remote side, bounded by
  `HETZNER_K3S_WAIT_SECONDS` (default 180).
- 2026-09-21 — the post-destroy sweep matches on the project label alone, as
  §4 specifies. That is safe today because nothing in the persistent Hetzner
  layer is a server, volume, load balancer, primary IP or firewall. HETZ-120
  adds persistent volumes on this target, and must narrow the volume leg of
  the sweep before it does.
- 2026-09-23 — the narrowing obligation above is retired, not done. It assumed
  HETZ-120 would add a `Retain` storage class. It does not: the data of record
  is a continuous WAL archive in S3, so the volume stays `Delete` and
  disposable, and a volume still present after the cascade is a leak in every
  case the sweep can see. The sweep keeps matching on the project label alone.
- 2026-09-22 — merged as `7771dc9` (PR #56) and closed. The operator ran the
  live Hetzner cluster cycle after the merge and accepted the result; this
  entry records that attestation, not evidence collected in the session that
  wrote it. The offline half of §13 is evidenced in the body of `99a96d7`:
  `make -n cluster-up cluster-down status` byte-identical to the pre-change
  baseline on both `aws` and `civo`, and `shellcheck` plus `bash -n` clean on
  every touched script. Two items in this spec are deliberately left for their
  own tickets: the `local-path`-versus-`hcloud-volumes` default-class check is
  a live k3s property that belongs to HETZ-045's acceptance, and the volume leg
  of the post-destroy sweep must be narrowed by HETZ-120 before persistent
  volumes exist on this target.

- 2026-09-22 — HETZ-060 closes a gap this spec left open. The post-destroy
  sweep selects every Hetzner resource with `-l project=$PROJECT_NAME`, which
  the feasibility spike had already shown cannot work for a load balancer: the
  cloud controller manager applies no labels of its own and names the load
  balancer an opaque hash (`research.md:268`, "a leak sweep cannot match it by
  name — HETZ-040 must use labels or enumerate"). Both halves of that sentence
  were unavailable, so the sweep was silently blind to the one resource the
  same spike proved outlives every server and bills indefinitely. HETZ-060
  resolves it from the other end: the `load-balancer.hetzner.cloud/name`
  annotation gives the load balancer a `<project>-` prefix, and `cluster-down`
  gains a second pass that matches on it, mirroring the Civo idiom. The
  labelled loop is unchanged and still runs first.

- 2026-09-22 — noted while HETZ-047 read this sweep, not changed here.
  `cluster-down.sh` has three `exit 1`s and no other failure code: a cluster
  that exists but is unreachable (`:39`), a root Application still present
  (`:44`), and leaks found and deleted (`:277`). So "refused to run" and
  "swept a leak and succeeded" are the same return code, and a caller cannot
  tell them apart. ADR 0026 makes the third case deliberate — delete
  immediately, still fail the run — and that part is correct. Only the
  conflation is the open question, and splitting it is a decision for this
  spec rather than a teardown-ordering change.

  `LEAK_COUNT` also counts categories, not resources: at most six on this
  target. It is never decremented, and every delete in the loop is silenced
  with `|| true`, so a failed delete and a successful one look identical
  until the next run.
