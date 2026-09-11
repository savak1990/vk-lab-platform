---
id: "HETZ-030"
title: "cluster-hetzner stack: firewall and a self-bootstrapped k3s cluster on three CAX21 servers"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "The platform owns a Kubernetes control plane for the first time: cloud-init, k3s flags, token handling, and replacement semantics all interact, and a wrong flag is invisible until the CCM stage"
effort_estimate: "Two sessions (8–12 h) including several real create/destroy cycles"
estimate_confidence: "low"
depends_on: ["HETZ-010", "HETZ-015", "HETZ-020", "HETZ-025"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-030 — Hetzner cluster Terraform

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up` creates a firewall and three `cax21`
servers in the persistent network. Cloud-init installs k3s: the first server
runs `k3s server`, the other two run `k3s agent` and join over the private
network. No Traefik, no ServiceLB, no k3s cloud controller. The stack writes
the values that later stages need to SSM. `cluster-down` destroys the
servers and the firewall and does not touch the persistent units. Terraform
creates no Kubernetes object; the CCM (HETZ-045) and everything above it are
installed later.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-hetzner/{firewall,k8s}`, modules
`hcloud-firewall` and `hcloud-k3s`, the cloud-init templates, the SSM
outputs, and the `lab-role` allowance for `*/cluster-hetzner/*` if HETZ-025
did not apply it. Not in scope: the readiness wait, kubeconfig fetch and
sweep (HETZ-040), the CCM (HETZ-045), the autoscaler (HETZ-170), and any
in-cluster resource.

## 3. Current state / evidence

- `terraform/live/cluster/eks/terragrunt.hcl:13-22` shows the cross-stack `dependency` pattern with `get_repo_root()`; `cluster-civo/k8s` reads `persistent-civo/network` the same way. This spec reads `persistent-hetzner/{network,ssh-key}`.
- `research.md`: `hcloud_server` requires `name`, `server_type`, `image`; `user_data` ≤ 32 KiB; `ssh_keys` immutable; `network { network_id, ip, alias_ips = [] }`; `firewall_ids`; `labels`; `public_net`. `hcloud_firewall` rules are default-deny inbound when attached, and outbound becomes default-deny as soon as any `out` rule exists. Firewalls attach to servers only.
- `research.md`: k3s flags `--disable-cloud-controller`, `--kubelet-arg cloud-provider=external`, `--disable servicelb,traefik`, `--tls-san`, `--node-ip`, `--node-external-ip`, `--flannel-iface`; the single-server datastore is SQLite; `--etcd-expose-metrics` applies to embedded etcd only. Metadata: `169.254.169.254/hetzner/v1/metadata/public-ipv4`; `userdata` is readable from the node without authentication.
- HETZ-020 supplies: the exact `cax21` and arm64 `ubuntu-24.04` image strings, the private NIC name, boot-to-Ready timing, and the label charset check.
- decisions.md: one schedulable server plus two agents (SQLite); metrics-server stays bundled; port 22 open to the world, key-only; control-plane metrics exposed on the private address.

## 4. Design and contracts

Firewall (`cluster-hetzner/firewall`, module `hcloud-firewall`):

- `hcloud_firewall` named `${project}-nodes`. Rules, all `direction = "in"`: tcp 22 from `0.0.0.0/0` and `::/0` (GitHub runners have no fixed IP; password auth is off on the image); tcp 6443 from the same; icmp from the same. **No `out` rules.** Adding one flips outbound to default-deny and breaks DNS and package fetches during cloud-init, the same trap CIVO-030 met with UDP/53. `apply_to { label_selector = "project=${project},role=node" }`. Labels per HETZ-015. Writes SSM `/${project}/cluster-hetzner/firewall/firewall_id`.
- NodePorts need no public rule: the LB reaches nodes over the private network (HETZ-060, `use-private-ip`), which firewalls do not filter.

Servers (`cluster-hetzner/k8s`, module `hcloud-k3s`):

- `random_password.k3s_token` (48 chars, alphanumeric). It is in state and inside `user_data`; both are disposable and regenerated on every `make up`; the metadata service exposes it to any process on the node. architecture.md §5 records this. It grants node join only.
- Three `hcloud_server`: `${project}-cp`, `${project}-worker-1`, `${project}-worker-2`; `server_type = "cax21"`, `image = <arm64 ubuntu-24.04 name from HETZ-020>`, `location = "nbg1"`, `ssh_keys = [dependency.ssh_key.outputs.id]`, `public_net { ipv4_enabled = true, ipv6_enabled = true }` (IPv4 is required: SSM has no IPv6 endpoint and Hetzner has no NAT), `network { network_id, ip, alias_ips = [] }` with `cp` at `10.0.1.10` and workers at `10.0.1.11`/`.12`, `labels = { project, scope = "platform", lifecycle = "disposable", managed_by = "terraform", role = "node", k3s_role = "server"|"agent" }`, `shutdown_before_deletion = true`, `depends_on` so the cp is created before the workers.
- `lifecycle { ignore_changes = [user_data, image, ssh_keys] }`. Rationale: a cloud-init edit or an image rename must never replace the control plane silently, because replacement is cluster loss. A k3s version bump is a `make down` then `make up`. The plan output states this in a comment in the module.
- Cloud-init, `templatefile()` per role, under 32 KiB, `#cloud-config` with a `runcmd`:
  - cp: `PUB=$(curl -sf http://169.254.169.254/hetzner/v1/metadata/public-ipv4)`; then `curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<pinned, e.g. v1.36.4+k3s1> K3S_TOKEN=<token> sh -s - server --disable-cloud-controller --disable servicelb,traefik,local-storage --kubelet-arg cloud-provider=external --node-ip 10.0.1.10 --node-external-ip $PUB --tls-san $PUB --flannel-iface <nic> --kube-controller-manager-arg bind-address=10.0.1.10 --kube-scheduler-arg bind-address=10.0.1.10 --write-kubeconfig-mode 0600`. No `--cluster-init`: the datastore is SQLite, so there is no etcd and no `--etcd-expose-metrics`. Metrics for the scheduler and controller manager bind to the private address only (HETZ-160 scrapes them there). `metrics-server` is not disabled (decision). `local-storage` is disabled so k3s does not install the `local-path` StorageClass as default; `hcloud-volumes` from the CSI chart (HETZ-050) is the only default class.
  - agents: `sh -s - agent --server https://10.0.1.10:6443 --token <token> --node-ip <private ip> --node-external-ip $PUB --kubelet-arg cloud-provider=external --flannel-iface <nic>`.
  - Both: `apt-get` is not run; the image has `curl`. A `bootcmd` waits until the private NIC has its address before `runcmd` starts.
- Outputs to SSM as plain String: `/${project}/cluster-hetzner/k8s/control_plane_ip`, `/…/control_plane_private_ip`, `/…/server_ids` (comma list). The kubeconfig is never an output and never in state; HETZ-040 fetches it over SSH.
- Terraform returns when the three servers are `running`, not when k3s is up. `cluster-up` (HETZ-040) waits for `kubectl get nodes` to list three nodes.

## 5. Files/components affected

- `terraform/live/cluster-hetzner/{firewall,k8s}/terragrunt.hcl` (new); `terraform/modules/hcloud-firewall`, `terraform/modules/hcloud-k3s` with `templates/{server,agent}.yaml.tftpl` (new); `versions.tf` pins `hetznercloud/hcloud` and `hashicorp/random`; lock files.
- `terraform/live/root.hcl`: already has `cluster-hetzner` in the lookup and the provider guard from HETZ-025; verify, no change expected.
- `terraform/modules/lab-role/main.tf`: `*/cluster-hetzner/*` (HETZ-025 adds it; confirm).
- `scripts/status.sh:59` reads `cluster-civo/k8s` for the Argo check; resolve the unit per provider (`${CLUSTER_DIR}/k8s`) — CIVO-030 §5 recorded the same hazard.
- State keys `cluster-hetzner/firewall` and `cluster-hetzner/k8s` in the hetzner bucket.

## 6. Implementation steps

1. Write the modules and templates; `terraform init`; render both templates with `terraform console` and check size and syntax with `cloud-init schema --config-file`.
2. Write the units with `dependency` blocks on `persistent-hetzner/{network,ssh-key}` and `cluster-hetzner/firewall`; mock outputs for validate and plan.
3. `terragrunt run --all plan` with `HCLOUD_TOKEN`; then `PROVIDER=hetzner make cluster-up`.
4. Until HETZ-040 lands, fetch the kubeconfig by hand: `ssh -i <decrypted key> root@<cp ip> cat /etc/rancher/k3s/k3s.yaml | sed "s/127.0.0.1/<cp ip>/"`. Run the §8 checks.
5. `PROVIDER=hetzner make cluster-down`; confirm with `hcloud server list`, `hcloud firewall list`; confirm network and SSH key remain.
6. Repeat once to prove idempotence and record timings.

## 7. Dependencies and blockers

HETZ-025 supplies network, subnet, and SSH key ids. HETZ-020 supplies the image and NIC names and the timing baseline. HETZ-040 can be drafted in parallel against the SSM outputs.

## 8. Acceptance criteria

- Three servers reach `running` and, within 5 minutes of `apply`, `kubectl get nodes` lists three nodes with the pinned k3s version. Before HETZ-045 they carry `node.cloudprovider.kubernetes.io/uninitialized` and CoreDNS is Pending; that is expected here, not a failure.
- `kubectl get pods -A` shows no `traefik`, `svclb-`, `local-path-provisioner` or `cloud-controller-manager` pods; `kubectl get sc` lists no `local-path`.
- `nc -zv <cp ip> 22 6443` succeeds; `nc -zv <cp ip> 80 443 10250 30000` fails; `nc -zv <worker ip> 6443` fails.
- `terraform state pull | jq` shows no `kubeconfig` key and no private key material; the join token is present and documented.
- SSM parameters exist under `/vk-hetzner-lab/cluster-hetzner/`.
- `cluster-down` leaves the network, subnet, and SSH key; `hcloud primary-ip list` is empty (server IPs are deleted with the servers).
- One create/destroy cycle costs under 1 EUR (three servers for under an hour at 0.0168 EUR/h each plus IPs).

## 9. Validation

Offline: `terraform fmt -check`, `validate`, `terragrunt run --all plan` with mocks, `cloud-init schema`, `shellcheck` on any wrapper. Real cloud: two create/destroy cycles. Cost: under 2 EUR total.

## 10. AWS regression protection

AWS: no AWS Terraform changes except the additive `lab-role` ARN if HETZ-025 left it; `terragrunt run --all plan` in `terraform/live/cluster` for the AWS project shows no changes; `make -n` goldens empty. Civo: `terragrunt run --all plan` in `terraform/live/cluster-civo` shows no changes; `status.sh` still reports the Civo cluster correctly after the unit-resolution edit; `PROVIDER=civo make -n cluster-up` unchanged.

## 11. Rollout and rollback/recovery

The destroy is the rollback. Nothing persistent is created. A failed cloud-init leaves running servers that bill; `cluster-down` removes them, and HETZ-040's sweep removes any that Terraform lost.

## 12. Risks and unresolved questions

- CAX21 stock: `apply` fails with a placement error when `nbg1` is sold out. The module exposes `server_type` as a variable so HETZ-175's fallback is a tfvars change; `apply` is not retried in a loop.
- The account default limit of 5 servers blocks a second cluster (CI) until a limit increase; HETZ-020 §4 item 11 decides whether to request it before M1.
- `user_data` exposure of the join token through the metadata service: accepted and documented; HETZ-170 revisits if the token gains any other power.
- `ignore_changes` on `user_data` means a flag fix ships only through `down`/`up`; the spec accepts this for a disposable cluster.
- The arm64 image name and the NIC name come from HETZ-020; if Hetzner renames either, `apply` fails loudly rather than booting a wrong image.
- A single control plane: an `apt` unattended-upgrade reboot takes the API down for about a minute; acceptable for a lab, noted for HETZ-150.
- Private-network readiness in cloud-init: if the NIC appears after `runcmd`, k3s binds the wrong interface. The `bootcmd` wait is the guard; HETZ-020 item 2 confirms the timing.

## 13. Definition of done

- [ ] Acceptance criteria met on two real cycles with timings recorded
- [ ] Modules formatted and validated; templates schema-checked
- [ ] AWS and Civo no-op plans recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
