---
id: "HETZ-040"
title: "Cluster scripts for Hetzner: hcloud helpers, SSH helper, existence proof, node-ssh, label-based leak sweep"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Shell branches with clear specifications; SSH key hygiene and the leak sweep must be correct but the logic is simple"
effort_estimate: "One session (4–6 h) including one real cluster-up/cluster-down cycle"
estimate_confidence: "medium"
depends_on: ["HETZ-030"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-19"
completed: ""
---

# HETZ-040 — Cluster scripts for Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-down`, `status` and the lifecycle guards work
on Hetzner, and the helpers every later Hetzner script needs exist in one
place: `hcloud_token`, `hcloud_cli`, `hcloud_list`, `hetzner_ssh`,
`cluster_exists`. Hetzner returns no kubeconfig from any API and Terraform
returns when servers boot, not when a cluster exists, so existence is
proved in two parts: the control-plane server carries the label, and
`/etc/kubernetes/admin.conf` exists on it. The leak sweep selects
resources by label, because load balancers, volumes and primary IPs
outlive the servers on Hetzner, and it removes autoscaled servers before
Terraform destroys the fixed ones. A new `make node-ssh` target opens a
shell on one node; on the other providers it prints a message and exits 0.

## 2. Scope and non-goals

In scope: the hetzner arms of `scripts/lib/provider.sh` (`hcloud_token`,
`hcloud_cli`, `hcloud_list`, `hetzner_ssh`, `cluster_exists`),
`scripts/cluster-down.sh` (pre-destroy and post-destroy sweeps),
`scripts/status.sh`, `scripts/lib/argo-state.sh`,
`scripts/require-persistent.sh`, the guard lists, the `Makefile` targets
`cluster-down`, `status`, `node-ssh`. Not in scope: `configure_kubeconfig`,
the `kubeconfig` Make arm and the `argo-state.sh` kubeconfig call, which
HETZ-035 owns because they need the kubeadm-created `admin.conf`; the
node Ready wait, which HETZ-037 owns because it needs Cilium;
`argo-up`/`argo-down` (HETZ-045, HETZ-047); tests (HETZ-130); the
autoscaler itself (HETZ-170) beyond the sweep that removes its servers.

## 3. Current state / evidence

- `scripts/lib/provider.sh:62-64` proves cluster existence with `civo kubernetes show`; `:77-88` fetches the kubeconfig with `civo kubernetes config` and renames the context to `${PROJECT_NAME}-civo` using the bash-3.2-safe `${kcfg[@]:+"${kcfg[@]}"}` idiom.
- `scripts/cluster-down.sh:51-95` sweeps Civo resources by name with `civo_list_names`. It can only report a leaked LB, because the civo CLI has no delete verb for it.
- `scripts/status.sh:59-60` reads `cluster_name` from `terraform/live/cluster-civo/k8s`.
- `Makefile:152-155` calls `civo_token` before the terragrunt apply; `:182-184` is the civo `kubeconfig` arm.
- HETZ-030 creates `${project}-cp-1` and `${project}-worker-1`, labels every server `project=${project}`, `scope=platform`, `lifecycle=disposable`, `managed_by=terraform`, `role=control-plane|worker`, and writes `/${project}/cluster-hetzner/k8s/{control_plane_ip,control_plane_private_ip,worker_ips,server_ids}` to SSM. Its cloud-init installs packages only, so a server can exist with no cluster on it. HETZ-025 commits the SSH public key and `secrets/<project>/hetzner-ssh-key.enc`.
- HETZ-035 creates the cluster with `kubeadm init`; `/etc/kubernetes/admin.conf` on the control plane is the durable sign that it ran. HETZ-170's autoscaler creates servers Terraform does not know, labelled `managed_by=autoscaler`.
- `hcloud` CLI v1.68.0 (verified 2026-09-19) is stateless when `HCLOUD_TOKEN` is set; it writes no file unless `hcloud context create` runs (research.md).

## 4. Design and contracts

- `hcloud_token()` decrypts `hetzner-token` (`SECRET_SCOPE=global`), masks it under `GITHUB_ACTIONS`, exports `HCLOUD_TOKEN`. `hcloud_cli()` runs `hcloud "$@"` with `HCLOUD_CONFIG` pointed at an empty `mktemp` file, so no context file is ever written. `hcloud_list(resource, selector)` runs `hcloud <resource> list -l "$selector" -o json` and prints names; an empty list prints nothing (the CLI prints `[]`, no plain-text trap as on Civo).
- `hetzner_ssh(ip, cmd...)`: decrypts `hetzner-ssh-key` into a `mktemp -d` directory as a mode-0600 file; `trap 'rm -rf "$dir"' EXIT INT TERM`; runs `ssh -i "$dir/key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$dir/known_hosts" -o ConnectTimeout=10 root@<ip> "$@"` and returns its exit status. HETZ-035 uses it for `kubeadm init`, `kubeadm join` and the `admin.conf` fetch; `cluster_exists` and `node-ssh` use it here. Nothing prints the key.
- `cluster_exists()` on hetzner is two-part: `hcloud_list server "project=${PROJECT_NAME},role=control-plane"` is non-empty AND `hetzner_ssh <cp ip> test -f /etc/kubernetes/admin.conf` succeeds, with the cp IP from SSM `/${PROJECT_NAME}/cluster-hetzner/k8s/control_plane_ip`. Servers without a cluster (a HETZ-030 apply that HETZ-035 never followed, or a failed `kubeadm init`) return false, so `cluster-down` skips the root-Application guard and destroys directly instead of asking a cluster that does not exist.
- Host-key trust: `accept-new` with a per-call known_hosts file trusts the first key seen for that IP. The IP is fresh from Terraform seconds earlier and the API server certificate check follows over TLS, so the window for a MITM is the SSH fetch itself. Pinning is possible through `hcloud server ssh` (same trust model) or by reading the host key from the server console; both are deferred (§12).
- `cluster-down.sh` on hetzner, **before** `terragrunt run --all destroy`: delete every server matching `project=${PROJECT_NAME},managed_by=autoscaler` (`hcloud server delete`) and poll `hcloud_list` until none remain (up to 3 min). The autoscaler is gone with the cluster by then (HETZ-047), so nothing recreates them; a server that Terraform never created would otherwise keep its primary IP and any attached volume alive after the fixed nodes are destroyed.
- `cluster-down.sh` on hetzner, after `terragrunt run --all destroy`: sweep by label `project=${PROJECT_NAME}` in this order — load balancers (`hcloud load-balancer delete`), volumes (`hcloud volume detach` then `delete`), servers not created by Terraform (`hcloud server delete`), primary IPs that are unassigned (`hcloud primary-ip delete`), firewalls (`hcloud firewall delete`). Report each deletion. A leaked volume or LB fails the run with exit 1 after the sweep, as on Civo, so a cascade bug surfaces.
- `status.sh` reads the unit `terraform/live/cluster-hetzner/k8s` when `PROVIDER=hetzner`; the prefix loop at `:27` gains `persistent-hetzner cluster-hetzner`. `argo-state.sh:30` gains a hetzner branch that calls `hcloud_token` and HETZ-035's `configure_kubeconfig`.
- `require-persistent.sh` on hetzner skips the `eks-access-identity` check and requires `persistent-hetzner/network` and `persistent-hetzner/ssh-key` state to be non-empty. `bootstrap-down.sh`, `persistent-down.sh` and `state-down.sh` guard lists gain the prefixes `persistent-hetzner` and `cluster-hetzner`.
- `Makefile`: `cluster-down` hetzner arm calls `hcloud_token` before the script; `node-ssh` (`NODE` defaults to `${PROJECT_NAME}-cp-1`) resolves the server's public IP with `hcloud_cli server ip "$NODE"` and runs `hetzner_ssh` interactively on hetzner; on aws and civo it prints `node-ssh: not applicable for PROVIDER=<p>` and exits 0.
- CI hygiene: the decrypted key exists only in the temp dir and is removed by the trap; nothing prints it. `GITHUB_ACTIONS` masking applies to the token only.

## 5. Files/components affected

`scripts/lib/provider.sh`, `scripts/cluster-down.sh`, `scripts/status.sh`,
`scripts/lib/argo-state.sh`, `scripts/require-persistent.sh`,
`scripts/bootstrap-down.sh`, `scripts/persistent-down.sh`, `scripts/state-down.sh`
(guard lists gain the two hetzner prefixes), `Makefile` (`cluster-down`,
`node-ssh`, `.PHONY`). No Terraform or GitOps changes.

## 6. Implementation steps

1. Add `hcloud_token`, `hcloud_cli`, `hcloud_list`, `hetzner_ssh`. Test `hcloud_cli` writes no file under `$HOME/.config/hcloud`; test `hetzner_ssh` against a HETZ-030 server and confirm the trap removes the key on Ctrl-C.
2. Add the two-part `cluster_exists`. Test both halves: servers without `admin.conf` (bare HETZ-030) and no servers at all.
3. Branch `cluster-down.sh`: the pre-destroy autoscaler sweep, then the post-destroy label sweep. Keep the aws and civo paths textually identical.
4. Update the guard lists, `status.sh`, `argo-state.sh`, `require-persistent.sh`, the Makefile arms.
5. Run `PROVIDER=hetzner make cluster-up` (HETZ-030 only), `make status`, `make node-ssh`, `make cluster-down`. Leave one labelled volume and one hand-made server labelled `managed_by=autoscaler` behind on purpose and confirm the sweeps delete both and the run exits 1 on the volume leak.

## 7. Dependencies and blockers

HETZ-030 supplies the servers, labels, SSM outputs and the SSH public key
binding. HETZ-025 supplies the encrypted private key. HETZ-035 consumes
`hetzner_ssh` and `cluster_exists` and supplies `configure_kubeconfig`;
it can be drafted in parallel.

## 8. Acceptance criteria

- On bare HETZ-030 servers `cluster_exists` returns false; `make cluster-down` destroys them without consulting Argo, sweeps a hand-made labelled volume and a hand-made `managed_by=autoscaler` server, and exits 1 because the volume leaked. `hcloud server list`, `load-balancer list`, `volume list`, `primary-ip list` filtered by `project=${PROJECT_NAME}` are all empty afterwards.
- On a HETZ-035 cluster `cluster_exists` returns true and `make cluster-down` refuses while a root Application exists.
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

- [ ] Acceptance criteria evidence recorded for hetzner
- [ ] `make -n` identity for aws and civo recorded
- [ ] `shellcheck` shows no new warnings
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — rewritten for kubeadm: kubeconfig and readiness moved to HETZ-035/037; two-part `cluster_exists`; autoscaled servers swept before destroy.
