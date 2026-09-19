---
id: "HETZ-030"
title: "cluster-hetzner stack: firewall and kubeadm-prepared cx33 nodes"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Package pinning across two apt repositories, module and hold ordering in cloud-init, and server replacement semantics all interact, and a wrong pin or a missing hold is invisible until HETZ-035 runs kubeadm init"
effort_estimate: "One session (4–6 h) including real create/destroy cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-010", "HETZ-015", "HETZ-025"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-19"
completed: ""
---

# HETZ-030 — Hetzner cluster nodes

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up` creates a firewall and
`control_plane_count` (1) plus `worker_count` (1) `cx33` servers in the
persistent network. Cloud-init installs `containerd.io`, `kubeadm`,
`kubelet`, `kubectl` and the kernel prerequisites, and nothing else: no
join token, no cluster state, no `kubeadm init`. HETZ-035 creates the
cluster over SSH against these prepared nodes. `cluster-down` destroys the
servers and the firewall only and does not touch the persistent units.
Terraform creates no Kubernetes object; the cloud controller manager
(HETZ-045) and everything above it are installed later.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-hetzner/{firewall,k8s}`, modules
`hcloud-firewall` and `hcloud-nodes`, the cloud-init template, the SSM
outputs, and the `lab-role` allowance for `*/cluster-hetzner/*` if
HETZ-025 did not apply it. Not in scope: `kubeadm init`/`kubeadm join`,
the Cilium install, the readiness wait and kubeconfig fetch (HETZ-035),
the cloud controller manager (HETZ-045), the autoscaler (HETZ-170), and
any in-cluster resource.

## 3. Current state / evidence

- `terraform/live/cluster/eks/terragrunt.hcl:13-14` and
  `terraform/live/cluster-civo/k8s/terragrunt.hcl:9-19` show the
  cross-stack `dependency` pattern with `get_repo_root()`, reading a
  persistent unit's outputs by `config_path`. This spec reads
  `persistent-hetzner/{network,ssh-key}` the same way; HETZ-025 §4 defines
  their output names (`network_id`, `ssh_key_id`).
- `hcloud_server` requires `name`, `server_type`, `image`; `user_data` is
  capped at 32 KiB; `ssh_keys` is immutable after create; `network {
  network_id, ip, alias_ips = [] }`; `firewall_ids`; `labels`; `public_net`.
  `hcloud_firewall` rules are default-deny inbound once attached, and
  outbound becomes default-deny as soon as any `out` rule exists.
  Firewalls attach to servers only.
  https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/server.md ;
  https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/firewall.md
- kubeadm packages come from one `pkgs.k8s.io` repository per minor
  (`.../core:/stable:/v1.36/deb/`), followed by `apt-mark hold kubelet
  kubeadm kubectl`; a minor upgrade edits the repo line.
  https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ ;
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
- Ubuntu 24.04's apt `containerd` package is 2.2.1, which satisfies
  Kubernetes 1.36's matrix but fails the 1.37 upgrade matrix; cloud-init
  installs `containerd.io` 2.3 (LTS) from Docker's repository instead,
  with config schema v3 and `SystemdCgroup = true`.
  https://github.com/containerd/containerd/blob/main/RELEASES.md ;
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Node prerequisites: kernel modules `overlay` and `br_netfilter`; sysctl
  `net.ipv4.ip_forward=1` and `net.bridge.bridge-nf-call-iptables=1`; swap
  off, and removed from `/etc/fstab` so a reboot does not re-enable it.
  https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- The hcloud cloud controller manager matches a node by
  `spec.providerID`, falling back to the node name against the Hetzner
  server name; the node's hostname must therefore equal the server name,
  or the fallback lookup fails.
  https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/hcloud/instances.go
- HETZ-020 confirmed the `cx33` server type string and the x86
  `ubuntu-24.04` image string with real creates in `nbg1`, `fsn1` and
  `hel1` on 2026-09-19, and that the private NIC is `enp7s0` at MTU 1450.
- decisions.md §1/§3: one schedulable control plane plus one worker,
  both `cx33`; Terraform owns the servers only, cloud-init installs
  packages only; `cluster-up` runs `kubeadm init`/`kubeadm join` and the
  Cilium install over SSH (HETZ-035); port 22 open to the world,
  key-only; control-plane metrics exposed on the private address.

## 4. Design and contracts

Firewall (`cluster-hetzner/firewall`, module `hcloud-firewall`):

- `hcloud_firewall` named `${project}-nodes`. Rules, all `direction =
  "in"`: tcp 22 from `0.0.0.0/0` and `::/0` (GitHub runners have no fixed
  IP; password auth is off on the image); tcp 6443 from the same; icmp
  from the same. **No `out` rules.** Adding one flips outbound to
  default-deny and breaks DNS and package fetches during cloud-init, the
  same trap CIVO-030 met with UDP/53. `apply_to { label_selector =
  "project=${project},scope=platform" }` — a label every node carries,
  including the autoscaler's, so the firewall covers autoscaled nodes
  too. Labels per HETZ-015. Writes SSM
  `/${project}/cluster-hetzner/firewall/firewall_id`.
- NodePorts need no public rule: the LB reaches nodes over the private
  network (HETZ-060, `use-private-ip`), which firewalls do not filter.

Servers (`cluster-hetzner/k8s`, module `hcloud-nodes`):

- One or more `hcloud_server` named `${project}-cp-1` … up to
  `control_plane_count`, and `${project}-worker-1` … up to `worker_count`.
  `server_type = var.server_type` (default `cx33`), `image =
  "ubuntu-24.04"`, `location = "nbg1"`, `ssh_keys =
  [dependency.ssh_key.outputs.ssh_key_id]`, `public_net { ipv4_enabled =
  true, ipv6_enabled = true }` (IPv4 is required: SSM has no IPv6
  endpoint and Hetzner has no managed NAT), `network { network_id, ip,
  alias_ips = [] }` with the control plane at `10.0.1.10` and workers
  from `10.0.1.11`, `labels = { project, scope = "platform", lifecycle =
  "disposable", managed_by = "terraform", role =
  "control-plane"|"worker" }`, `shutdown_before_deletion = true`. The
  control plane is created before any worker (`depends_on`), because a
  worker's `kubeadm join` target must already exist by the time HETZ-035
  runs.
- `lifecycle { ignore_changes = [user_data, image, ssh_keys] }`.
  Rationale: a cloud-init edit or an image rename must never replace the
  control plane silently, because replacement is cluster loss. A package
  version bump ships only through a `make down` then `make up`. The
  module records this in a comment.
- Variables: `kubernetes_version` and `containerd_version` have no
  default — the `Makefile`'s hetzner `cluster-up` arm exports them as
  `TF_VAR_kubernetes_version` and `TF_VAR_containerd_version` from
  `scripts/lib/versions.sh`, so a missing export fails loudly rather than
  silently pinning a stale version. `control_plane_count` defaults to 1,
  `worker_count` defaults to 1, `server_type` defaults to `cx33`.
- One cloud-init template, `templates/node.yaml.tftpl`, rendered per
  server with `templatefile()`, `#cloud-config`, under 32 KiB:
  - `bootcmd` waits until the private NIC (`enp7s0`) carries its address,
    the same guard the earlier design used, so a later step never binds
    the wrong interface.
  - `write_files` places `/etc/modules-load.d/k8s.conf` (`overlay`,
    `br_netfilter`), `/etc/sysctl.d/k8s.conf` (the two sysctl keys), the
    Docker apt source and keyring, and the `pkgs.k8s.io` v1.36 apt source
    and keyring.
  - `runcmd`: `swapoff -a` and the matching `/etc/fstab` edit;
    `apt-get update`; `apt-get install -y
    containerd.io=<containerd_version pin> kubelet=<kubernetes_version
    pin> kubeadm=<kubernetes_version pin> kubectl=<kubernetes_version
    pin>`; `containerd config default` written with `SystemdCgroup =
    true`; `systemctl enable --now containerd kubelet`; `apt-mark hold
    containerd.io kubelet kubeadm kubectl`.
  - No `kubeadm init`, no join token, no cluster state anywhere in
    `user_data`.
- Outputs to SSM as plain String:
  `/${project}/cluster-hetzner/k8s/control_plane_ip`,
  `/…/control_plane_private_ip`, `/…/worker_ips` (comma-separated list),
  `/…/server_ids` (comma-separated list). No kubeconfig, no token, no
  private key material is ever an output or ever enters state.
- Terraform returns when every server reaches `running`, not when
  Kubernetes is up. HETZ-035 waits for the cluster.

## 5. Files/components affected

- `terraform/live/cluster-hetzner/{firewall,k8s}/terragrunt.hcl` (new);
  `terraform/modules/hcloud-firewall`, `terraform/modules/hcloud-nodes`
  with `templates/node.yaml.tftpl` (new); `versions.tf` pins
  `hetznercloud/hcloud`; lock files.
- `scripts/lib/versions.sh` gains `KUBERNETES_VERSION` and
  `CONTAINERD_VERSION`.
- `Makefile`: the hetzner `cluster-up` arm exports
  `TF_VAR_kubernetes_version` and `TF_VAR_containerd_version` before the
  apply.
- `terraform/live/root.hcl`: the lifecycle and provider lookups gain
  `cluster-hetzner`; verify against the existing `cluster-civo` entries
  rather than assume they are already present.
- `terraform/modules/lab-role/main.tf`: verify the `*/cluster-hetzner/*`
  SSM ARN pattern exists (HETZ-025 adds it) rather than assume it.
- `scripts/status.sh:59`: resolve the Terraform unit per provider
  (`${CLUSTER_DIR}/k8s`) instead of the hard-coded civo path; CIVO-030 §5
  recorded the same hazard.
- State keys `cluster-hetzner/firewall` and `cluster-hetzner/k8s` in the
  hetzner bucket.

## 6. Implementation steps

1. Write the modules and the cloud-init template; render it with
   `terraform console` and check size and syntax with `cloud-init schema
   --config-file`.
2. Write the units with `dependency` blocks on
   `persistent-hetzner/{network,ssh-key}` and `cluster-hetzner/firewall`;
   mock outputs for `validate` and `plan`.
3. `terragrunt run --all plan` with `HCLOUD_TOKEN`; then `PROVIDER=hetzner
   make cluster-up`.
4. Verify the §8 checks over SSH against both servers.
5. `PROVIDER=hetzner make cluster-down`; confirm with `hcloud server
   list` and `hcloud firewall list`; confirm the network and SSH key
   remain; repeat once to prove idempotence and record timings.

## 7. Dependencies and blockers

HETZ-025 supplies the network, subnet and SSH key ids. HETZ-010 supplies
the `PROVIDER=hetzner` surface and the token helper. HETZ-015 supplies the
governance base this spec's labels and ADR reference depend on. HETZ-020's
image, NIC-name and timing evidence is carried into §3 but is not a
blocking dependency here. HETZ-035, which turns these prepared nodes into
a cluster, can be drafted in parallel against the SSM outputs this spec
writes.

## 8. Acceptance criteria

- Both servers reach `running` within a few minutes of `apply`.
- Over SSH on the control plane: `kubeadm version -o short` prints the
  pinned `kubernetes_version`; `containerd --version` prints a 2.3.x
  version; `kubeadm config images pull --kubernetes-version v1.36.x`
  exits 0; `systemctl is-active containerd` prints `active`.
- `kubectl get nodes` is not expected to succeed — no cluster exists yet.
- `nc -zv <cp ip> 22 6443` succeeds; `nc -zv <cp ip> 80 443 10250 30000`
  fails.
- `terraform state pull | jq` shows no `kubeconfig` key, no join token,
  and no private key material.
- SSM parameters exist under `/vk-hetzner-lab/cluster-hetzner/`, including
  `worker_ips`.
- `cluster-down` leaves the network, subnet, and SSH key; `hcloud
  primary-ip list` is empty (server IPs are deleted with the servers).
- One create/destroy cycle costs under 0.20 EUR (two `cx33` for under an
  hour at 0.0160 EUR/h each, plus the primary IPs).

## 9. Validation

Offline: `terraform fmt -check`, `validate`, `terragrunt run --all plan`
with mocks, `cloud-init schema`, `shellcheck` on any wrapper. Real cloud:
two create/destroy cycles. Cost: under 0.40 EUR total.

## 10. AWS regression protection

AWS: no AWS Terraform changes except the additive `lab-role` ARN if
HETZ-025 left it; `terragrunt run --all plan` in `terraform/live/cluster`
for the AWS project shows no changes; `make -n` goldens empty. Civo:
`terragrunt run --all plan` in `terraform/live/cluster-civo` shows no
changes; `status.sh` still reports the Civo cluster correctly after the
unit-resolution edit; `PROVIDER=civo make -n cluster-up` unchanged.

## 11. Rollout and rollback/recovery

The destroy is the rollback. Nothing persistent is created. A failed
cloud-init leaves running servers that bill; `cluster-down` removes them,
and HETZ-040's sweep removes any that Terraform lost.

## 12. Risks and unresolved questions

- `cx33` stock: `apply` fails with a placement error when `nbg1` is sold
  out. The module exposes `server_type` as a variable so HETZ-175's
  fallback is a tfvars change; `apply` is not retried in a loop.
- If cloud-init's Docker apt source is skipped or misconfigured, `apt-get
  install` falls back to Ubuntu's own `containerd` package (2.2.1), which
  is too old for a later 1.37 upgrade even though it satisfies 1.36 today.
- `user_data` size: the template plus both apt keyrings must stay under
  32 KiB; the render step in §6 checks this, not `apply`.
- The image name comes from HETZ-020; if Hetzner renames it, `apply`
  fails loudly rather than booting a wrong image.
- `ignore_changes` on `user_data` means a package-pin fix ships only
  through a `down`/`up` cycle; accepted for a disposable cluster.
- Port 22 open to `0.0.0.0/0`, key-only: brute-force noise in `auth.log`
  is accepted, not mitigated, in M1.
- The node's hostname must equal the Hetzner server name for the cloud
  controller manager's fallback lookup (§3); a template that sets a
  different hostname breaks HETZ-045 silently until then.

## 13. Definition of done

- [ ] Acceptance criteria met on two real cycles with timings recorded
- [ ] Modules formatted and validated; cloud-init template schema-checked
- [ ] AWS and Civo no-op plans recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — node shape revised to two fixed `cx33` plus 0–2 autoscaled
  (ceiling 4) (decisions.md §3, Node shape): every ARM server type failed a
  real create in every EU location; `cx33` succeeded in all three.
- 2026-09-19 — rewritten for kubeadm: cloud-init installs packages only,
  the cluster is created by HETZ-035; folder renamed.
- 2026-09-19 — `templates/node.yaml.tftpl` is also rendered by HETZ-165
  for autoscaled nodes; keep it substitution-friendly (only
  `${kubernetes_version}`, `${containerd_version}` placeholders).
