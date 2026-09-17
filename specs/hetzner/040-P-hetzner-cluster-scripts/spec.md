---
id: "HETZ-040"
title: "Cluster scripts for Hetzner: SSH kubeconfig, k3s readiness wait, status, node-ssh, label-based leak sweep"
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
updated: "2026-09-11"
completed: ""
---

# HETZ-040 — Cluster scripts for Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up`, `cluster-down`, `status`, and `kubeconfig`
work on Hetzner. Hetzner returns no kubeconfig from any API, so the scripts
fetch it over SSH from the k3s control plane. Terraform returns when the
servers boot, not when k3s runs, so `cluster-up` waits for three Ready
nodes before it exits. The leak sweep selects resources by label, because
load balancers, volumes and primary IPs outlive the servers on Hetzner.
A new `make node-ssh` target opens a shell on one node; on the other
providers it prints a message and exits 0.

## 2. Scope and non-goals

In scope: the hetzner arms of `scripts/lib/provider.sh`
(`cluster_exists`, `configure_kubeconfig`, `hcloud_cli`, `hcloud_list`,
`hcloud_token`, `wait_for_k3s`), `scripts/cluster-down.sh`,
`scripts/status.sh`, `scripts/lib/argo-state.sh`, `scripts/require-persistent.sh`,
the `Makefile` targets `cluster-up`, `kubeconfig`, `node-ssh`. Not in scope:
`argo-up`/`argo-down` (HETZ-045), tests (HETZ-130), the autoscaler sweep
details beyond the generic label rule (HETZ-170).

## 3. Current state / evidence

- `scripts/lib/provider.sh:62-64` proves cluster existence with `civo kubernetes show`; `:77-88` fetches the kubeconfig with `civo kubernetes config` and renames the context to `${PROJECT_NAME}-civo` using the bash-3.2-safe `${kcfg[@]:+"${kcfg[@]}"}` idiom.
- `scripts/cluster-down.sh:51-95` sweeps Civo resources by name with `civo_list_names`. It can only report a leaked LB, because the civo CLI has no delete verb for it.
- `scripts/status.sh:59-60` reads `cluster_name` from `terraform/live/cluster-civo/k8s`.
- `Makefile:152-155` calls `civo_token` before the terragrunt apply; `:182-184` is the civo `kubeconfig` arm.
- HETZ-030 writes `/${project}/cluster-hetzner/k8s/control_plane_ip` to SSM and labels every server `project=${project}`, `role=control-plane|worker`. HETZ-025 commits the SSH public key and `secrets/<project>/hetzner-ssh-key.enc`.
- `hcloud` CLI v1.67.0 is stateless when `HCLOUD_TOKEN` is set; it writes no file unless `hcloud context create` runs (research.md).

## 4. Design and contracts

- `hcloud_token()` decrypts `hcloud-token`, masks it under `GITHUB_ACTIONS`, exports `HCLOUD_TOKEN`. `hcloud_cli()` runs `hcloud "$@"` with `HCLOUD_CONFIG` pointed at an empty `mktemp` file, so no context file is ever written. `hcloud_list(resource, selector)` runs `hcloud <resource> list -l "$selector" -o json` and prints names; an empty list prints nothing (the CLI prints `[]`, no plain-text trap as on Civo).
- `cluster_exists()` on hetzner: `hcloud_list server "project=${PROJECT_NAME},role=control-plane"` is non-empty.
- `configure_kubeconfig([path])` on hetzner: decrypt `hetzner-ssh-key` into a `mktemp` file with mode 0600 inside a `mktemp -d`; `trap 'rm -rf "$dir"' EXIT INT TERM`; read the control-plane IP from SSM `/${PROJECT_NAME}/cluster-hetzner/k8s/control_plane_ip`; run `ssh -i "$key" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$dir/known_hosts" -o ConnectTimeout=10 root@<ip> cat /etc/rancher/k3s/k3s.yaml`; rewrite `https://127.0.0.1:6443` to `https://<ip>:6443`; rename the context, cluster and user to `${PROJECT_NAME}-hetzner` (delete a stale context first); merge into the target kubeconfig with `KUBECONFIG=<target>:<tmp> kubectl config view --flatten`. Every optional `--kubeconfig` expansion keeps the `${kcfg[@]:+"${kcfg[@]}"}` idiom.
- Host-key trust: `accept-new` with a per-call known_hosts file trusts the first key seen for that IP. The IP is fresh from Terraform seconds earlier and the API server certificate check follows over TLS, so the window for a MITM is the SSH fetch itself. Pinning is possible through `hcloud server ssh` (same trust model) or by reading the host key from the server console; both are deferred. Record the decision in §12.
- `wait_for_k3s()` runs at the end of the `cluster-up` recipe on hetzner: poll SSH `test -f /etc/rancher/k3s/k3s.yaml` every 10 s up to 5 min; then `configure_kubeconfig` into a temp file; then poll `kubectl get nodes` until three nodes report `Ready` (up to 10 min total). Nodes still carry `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` at this point; that is expected and is cleared by HETZ-045. On timeout the recipe fails and prints the node list.
- `cluster-down.sh` on hetzner, after `terragrunt run --all destroy`: sweep by label `project=${PROJECT_NAME}` in this order — load balancers (`hcloud load-balancer delete`), volumes (`hcloud volume detach` then `delete`), servers not created by Terraform (`hcloud server delete`; the autoscaler adds these in M2), primary IPs that are unassigned (`hcloud primary-ip delete`), firewalls (`hcloud firewall delete`). Report each deletion. A leaked volume or LB fails the run with exit 1 after the sweep, as on Civo, so a cascade bug surfaces.
- `status.sh` reads `cluster_name` from `terraform/live/cluster-hetzner/k8s` when `PROVIDER=hetzner`; the prefix loop at `:27` gains `persistent-hetzner cluster-hetzner`. `argo-state.sh:30` gains a hetzner branch that calls `hcloud_token` and `configure_kubeconfig`.
- `require-persistent.sh` on hetzner skips the `eks-access-identity` check and requires `persistent-hetzner/network` and `persistent-hetzner/ssh-key` state to be non-empty.
- `Makefile`: `cluster-up` hetzner arm calls `hcloud_token`, applies, then `wait_for_k3s`; `kubeconfig` hetzner arm calls `configure_kubeconfig`; `node-ssh` (`NODE` defaults to `${PROJECT_NAME}-cp-1`) decrypts the key to a temp file and runs `ssh` interactively on hetzner; on aws and civo it prints `node-ssh: not applicable for PROVIDER=<p>` and exits 0.
- CI hygiene: the decrypted key exists only in the temp dir and is removed by the trap; nothing prints it. `GITHUB_ACTIONS` masking applies to the token only.

## 5. Files/components affected

`scripts/lib/provider.sh`, `scripts/cluster-down.sh`, `scripts/status.sh`,
`scripts/lib/argo-state.sh`, `scripts/require-persistent.sh`,
`scripts/bootstrap-down.sh`, `scripts/persistent-down.sh`, `scripts/state-down.sh`
(guard lists gain the two hetzner prefixes), `Makefile` (`cluster-up`,
`kubeconfig`, `node-ssh`, `.PHONY`). No Terraform or GitOps changes.

## 6. Implementation steps

1. Add the lib functions. Test `hcloud_cli` writes no file under `$HOME/.config/hcloud`. Test `cluster_exists` in both cases.
2. Add `configure_kubeconfig` and `wait_for_k3s`. Test against the HETZ-030 cluster. Confirm the trap removes the key on Ctrl-C.
3. Branch `cluster-down.sh`. Keep the aws and civo paths textually identical.
4. Update the guard lists, `status.sh`, `argo-state.sh`, `require-persistent.sh`, the Makefile arms.
5. Run `PROVIDER=hetzner make cluster-up`, `make kubeconfig`, `make status`, `make node-ssh`, `make cluster-down`. Leave one volume behind on purpose once (create a PVC by hand) and confirm the sweep deletes it and fails the run.

## 7. Dependencies and blockers

HETZ-030 supplies the servers, labels, SSM outputs and the SSH public key
binding. HETZ-025 supplies the encrypted private key. Parallel: the
HETZ-045 draft.

## 8. Acceptance criteria

- `PROVIDER=hetzner make cluster-up` exits only after `kubectl get nodes` shows three Ready nodes, within 10 minutes.
- `make kubeconfig` produces context `${PROJECT_NAME}-hetzner` whose server is the public control-plane IP; `kubectl get nodes` works from the operator machine.
- `make cluster-down` refuses while a root Application exists; after `argo-down` it destroys the servers, sweeps by label, and reports zero leaks. `hcloud server list`, `load-balancer list`, `volume list`, `primary-ip list` filtered by `project=${PROJECT_NAME}` are all empty.
- `make node-ssh` opens a shell on hetzner and exits 0 with a message on aws and civo.
- No script prints the Hetzner token or the SSH private key; the temp dir is gone after every run, including an interrupted one.

## 9. Validation

Offline: `shellcheck` against the CIVO-045 baseline; `bash -n`. Real cloud: one Hetzner cycle (three CAX21 for under an hour, about 0.10 EUR). AWS and Civo: dry runs only.

## 10. AWS regression protection

The aws and civo branches do not change textually beyond the guard-list
additions. Diff `make -n cluster-up`, `make -n kubeconfig`, `make -n
cluster-down` for `PROVIDER=aws` and `PROVIDER=civo` against the recorded
output before this change: identical. Run `PROVIDER=civo make status`
against the civo project and compare with the recorded baseline.

## 11. Rollout and rollback/recovery

Revert the scripts. There is no data risk. `cluster-down` never touches
the persistent units, because they live in a separate stack directory.

## 12. Risks and unresolved questions

- `accept-new` host-key trust on first contact is a known gap. Mitigation candidates: read the host key fingerprint from the Hetzner console API (not available), or generate the host key in cloud-init from a value Terraform knows (`ssh_keys` is for user keys only). Documented, not solved in M1.
- SSH on port 22 from `0.0.0.0/0` (HETZ-030) is the price of GitHub runners with no fixed IP; key-only auth holds.
- `kubectl get nodes` may report Ready before the CSI node plugin and CCM run; that is fine here, HETZ-045 owns the next gate.
- Deleting a volume that is still attached fails; the sweep detaches first, and a volume attached to a server that Terraform already destroyed reports `available`.
- The `hcloud` CLI version must be pinned in docs and CI (HETZ-140); flag names changed across releases.

## 13. Definition of done

- [ ] Acceptance criteria evidence recorded for hetzner
- [ ] `make -n` identity for aws and civo recorded
- [ ] `shellcheck` shows no new warnings
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
