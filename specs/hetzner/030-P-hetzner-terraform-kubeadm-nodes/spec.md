---
id: "HETZ-030"
title: "cluster-hetzner stack: firewall, a self-initializing kubeadm control plane and package-prepared workers on cx33"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Package pinning across two apt repositories, module and hold ordering in cloud-init, the control plane's self-initialization at first boot and server replacement semantics all interact, and a wrong pin or a missing hold surfaces only as a failed boot-time kubeadm init read back over SSH"
effort_estimate: "One session (4–6 h) including real create/destroy cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-010", "HETZ-015", "HETZ-025"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-20"
completed: ""
---

# HETZ-030 — Hetzner cluster nodes

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up` creates a firewall and
`control_plane_count` (1) plus `worker_count` (1) `cx33` servers in the
persistent network. Every node's cloud-init installs `containerd.io`,
`kubeadm`, `kubelet`, `kubectl` and the kernel prerequisites. On the
control plane it also renders `/root/kubeadm-config.yaml` from the node's
own metadata (the public IPv4 for `apiServer.certSANs`), runs `kubeadm
init --config …`, installs Cilium with helm, and drops a
`/var/lib/lab/cp-bootstrap-done` marker; the control plane is therefore a
working single-node cluster about two minutes after create, in parallel
with Terraform finishing. Workers install packages only. No token, CA or
kubeconfig ever enters `user_data` or Terraform state — kubeadm generates
all of them on the control plane at boot and they stay there. HETZ-035
joins the workers over SSH and fetches the kubeconfig. `cluster-down`
destroys the servers and the firewall only and does not touch the
persistent units. Terraform creates no Kubernetes object: it renders
`user_data`, holds no kubeconfig, and configures no Kubernetes or Helm
provider. The cloud controller manager (HETZ-045) and everything above it
are installed later.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-hetzner/{firewall,k8s}`, modules
`hcloud-firewall` and `hcloud-nodes`, both cloud-init templates including
the control plane's boot-time `kubeadm init` and Cilium install, the SSM
outputs, and the `lab-role` allowance for `*/cluster-hetzner/*` if
HETZ-025 did not apply it. Not in scope: `kubeadm join`, the kubeconfig
fetch and the idempotent re-run (HETZ-035); the Cilium helm values, their
version pin and the readiness wait (HETZ-037) — this spec only carries the
command line HETZ-037 defines; the cloud controller manager (HETZ-045);
the autoscaler (HETZ-170); and any Kubernetes object Terraform would own.

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
- decisions.md §1/§3 (row "Bootstrap driver", decided 2026-09-20): one
  schedulable control plane plus one worker, both `cx33`; Terraform owns
  the servers only; the control plane's cloud-init runs `kubeadm init` and
  the Cilium install at first boot, worker cloud-init installs packages
  only, and `cluster-up` runs `kubeadm join` and fetches the kubeconfig
  (HETZ-035); port 22 open to the world, key-only; control-plane metrics
  exposed on the private address through this spec's kubeadm config.
- research.md, "Metadata service": `169.254.169.254/hetzner/v1/metadata`
  serves the node's own `public-ipv4` without authentication, so the
  control plane fills `apiServer.certSANs` at boot instead of taking the
  address from an `apply`-time Terraform value. The same row is why no
  secret may be placed in `user_data`: `/hetzner/v1/userdata` is readable
  by any process on the node, including a `hostNetwork` pod.

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
- Variables: `kubernetes_version`, `containerd_version`,
  `cilium_chart_version` and `helm_version` have no default — the
  `Makefile`'s hetzner `cluster-up` arm exports all four as
  `TF_VAR_*` from `scripts/lib/versions.sh`, so a missing export fails
  loudly rather than silently pinning a stale version.
  All four are declared in `scripts/lib/versions.sh` by this spec, which
  consumes them as `TF_VAR_*`; HETZ-037 owns the rationale for the Cilium
  values and for `CILIUM_CHART_VERSION`'s value, not its declaration.
  `worker_count` defaults to 1 and `server_type` defaults to `cx33`.
  `control_plane_count` defaults to 1 and carries `validation { condition
  = var.control_plane_count == 1; error_message = "HA control plane needs
  a stable controlPlaneEndpoint; see decisions.md" }` until an HA spec
  lifts it.
- Two cloud-init templates under `templates/`, each a standalone
  `#cloud-config` document rendered with `templatefile()`. They are not
  composed: two `#cloud-config` documents cannot be concatenated, and
  threading a control-plane fragment through the node template would break
  the two-placeholder property HETZ-165 depends on, so the package section
  is duplicated deliberately.
- `templates/node.yaml.tftpl`, the package template, rendered for every
  worker and also read and substituted by HETZ-165 for autoscaled nodes,
  which is why it keeps exactly the two placeholders
  `${kubernetes_version}` and `${containerd_version}`:
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
  - No `kubeadm init`, no join token, no cluster state anywhere in a
    worker's `user_data`.
- `templates/control-plane.yaml.tftpl`, rendered only for
  `${project}-cp-1`: the package section above, plus the kubeadm config
  and the boot-time init.
  - `write_files` adds `/root/kubeadm-config.yaml`, kubeadm API v1beta4
    (research.md, "kubeadm config for an external cloud provider"):
    `InitConfiguration` with `nodeRegistration.name = ${server_name}`
    (the CCM's fallback lookup matches the node name against the Hetzner
    server name), `nodeRegistration.kubeletExtraArgs`
    `cloud-provider=external` and `node-ip=10.0.1.10`,
    `nodeRegistration.taints: []` so the control plane stays schedulable,
    `localAPIEndpoint.advertiseAddress 10.0.1.10`; `ClusterConfiguration`
    with `kubernetesVersion v${kubernetes_version}`,
    `controlPlaneEndpoint "10.0.1.10:6443"`, `networking.podSubnet
    10.244.0.0/16`, `networking.serviceSubnet 10.96.0.0/12`,
    `apiServer.certSANs` (filled at boot, below),
    `controllerManager.extraArgs` and `scheduler.extraArgs`
    `bind-address=10.0.1.10`, `etcd.local.extraArgs
    listen-metrics-urls=http://10.0.1.10:2381`; `KubeletConfiguration`
    with `cgroupDriver: systemd`, `systemReserved: {cpu: 500m, memory:
    1Gi}`, `kubeReserved: {cpu: 250m, memory: 512Mi}` and `evictionHard:
    {memory.available: 300Mi}` — the control plane is schedulable by
    decision (`nodeRegistration.taints: []`), so these reservations keep
    etcd and the API server out of memory pressure when workloads fill
    the node; `KubeProxyConfiguration` with `metricsBindAddress:
    10.0.1.10:10249`.
  - kubeadm stores the `KubeletConfiguration` given at `init` in the
    `kube-system/kubelet-config` ConfigMap, and every `kubeadm join`
    downloads it. `cgroupDriver`, `systemReserved`, `kubeReserved` and
    `evictionHard` are therefore cluster-wide from this one document:
    Terraform workers (HETZ-035) and autoscaled workers (HETZ-165) inherit
    them on join and repeat none of it.
    https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/kubelet-integration/
  - `runcmd`, after the package steps: wait for `enp7s0`; read the node's
    own public IPv4 from `169.254.169.254/hetzner/v1/metadata` and write
    it into `apiServer.certSANs`, so no `apply`-time value pins the
    address; `kubeadm init --config /root/kubeadm-config.yaml`; install
    helm from the pinned tarball
    (`${helm_version}`); `helm repo add cilium https://helm.cilium.io`;
    `helm upgrade --install cilium cilium/cilium --version
    ${cilium_chart_version} -n kube-system --set ipam.mode=kubernetes
    --set routingMode=tunnel --set tunnelProtocol=vxlan --set
    kubeProxyReplacement=false --set operator.replicas=1 --kubeconfig
    /etc/kubernetes/admin.conf` — the values and the pin belong to
    HETZ-037, which explains each one; finally `touch
    /var/lib/lab/cp-bootstrap-done`.
  - The marker means `kubeadm init` returned and the Cilium release was
    created, not that Cilium is healthy: the helm call carries no
    `--wait`. HETZ-037's readiness wait is what proves health.
  - No token, CA or kubeconfig enters `user_data` or Terraform state;
    kubeadm generates them on the node and they stay there.
  - Size: the two apt keyrings dominate both renders. The worker render
    is expected at 8–10 KiB and the control-plane render at 12–16 KiB (the
    kubeadm document plus the helm lines), both well under the 32 KiB cap.
    §6 step 1 measures them rather than assuming.
- Outputs to SSM as plain String:
  `/${project}/cluster-hetzner/k8s/control_plane_ip`,
  `/…/control_plane_private_ip`, `/…/worker_ips` (comma-separated list),
  `/…/server_ids` (comma-separated list). No kubeconfig, no token, no
  private key material is ever an output or ever enters state.
- Terraform returns when every server reaches `running`, not when the
  control plane's cloud-init finishes. HETZ-035 waits for the
  `cp-bootstrap-done` marker before it joins anything.

## 5. Files/components affected

- `terraform/live/cluster-hetzner/{firewall,k8s}/terragrunt.hcl` (new);
  `terraform/modules/hcloud-firewall`, `terraform/modules/hcloud-nodes`
  with `templates/node.yaml.tftpl` and
  `templates/control-plane.yaml.tftpl` (new); `versions.tf` pins
  `hetznercloud/hcloud`; lock files.
- `scripts/lib/versions.sh` gains `KUBERNETES_VERSION`,
  `CONTAINERD_VERSION`, `HELM_VERSION` and `CILIUM_CHART_VERSION`; this
  spec declares all four, and HETZ-037 owns the Cilium pin's value and
  rationale.
- `Makefile`: the hetzner `cluster-up` arm exports
  `TF_VAR_kubernetes_version`, `TF_VAR_containerd_version`,
  `TF_VAR_helm_version` and `TF_VAR_cilium_chart_version` before the
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

1. Write the modules and both cloud-init templates; render each with
   `terraform console`, check size and syntax with `cloud-init schema
   --config-file`, and diff the package sections of the two templates —
   they must be identical.
2. Write the units with `dependency` blocks on
   `persistent-hetzner/{network,ssh-key}` and `cluster-hetzner/firewall`;
   mock outputs for `validate` and `plan`.
3. `terragrunt run --all plan` with `HCLOUD_TOKEN`; then `PROVIDER=hetzner
   make cluster-up`.
4. Watch the control plane's first boot over SSH (`cloud-init status
   --wait`, then `journalctl -u cloud-final`), record the time from
   create to `/var/lib/lab/cp-bootstrap-done`, and verify the §8 checks
   against both servers.
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
- Over SSH on the control plane within `HETZNER_CP_BOOTSTRAP_SECONDS`
  (default 600 s) of `apply`: `cloud-init
  status --wait` exits 0; `/etc/kubernetes/admin.conf` exists; `kubectl
  --kubeconfig /etc/kubernetes/admin.conf get nodes` lists the control
  plane `Ready` (Cilium is up) and still carrying
  `node.cloudprovider.kubernetes.io/uninitialized`;
  `/var/lib/lab/cp-bootstrap-done` exists.
- Over SSH on a worker: `kubeadm` is installed and no cluster file exists
  (`/etc/kubernetes/kubelet.conf` absent) — the worker is prepared, not
  joined.
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
- A `kubeadm init` that fails at boot is invisible to Terraform, which
  reports a healthy `running` server: it is read only with `cloud-init
  status --long` and `journalctl -u kubelet` over SSH, which HETZ-035
  prints from the control plane when its wait times out.
- An HA spec adds `--upload-certs` and the certificate key handling; at
  one control plane the flag would only create a `kubeadm-certs` Secret
  nobody reads, so `kubeadm init` carries no such flag here.
- A helm download or `helm upgrade --install` that fails at boot after a
  successful `kubeadm init` leaves a cluster with no CNI and no marker.
  `tail -n 50 /var/log/cloud-init-output.log` and `journalctl -u
  cloud-final` on the control plane show it; HETZ-035's timeout path
  prints both.
- The package section is duplicated in both templates, so a package or
  repository change made in one and not the other gives workers and the
  control plane different versions; the §6 render step diffs the two
  package sections.
- `control_plane_count > 1` fails at `plan` on the variable's own
  `validation` block, earlier than HETZ-035's explicit rejection: the
  control-plane template hardcodes `10.0.1.10` for
  `advertiseAddress` and `controlPlaneEndpoint`, so a second control plane
  would render a wrong config at the Terraform layer.

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
- 2026-09-20 — option C: `kubeadm init` and the Cilium install move into
  the control plane's cloud-init, which gains its own
  `templates/control-plane.yaml.tftpl`; `node.yaml.tftpl` stays the
  package-only worker template HETZ-165 reuses; the script joins the
  workers and fetches the kubeconfig (decisions.md §3, "Bootstrap
  driver").
- 2026-09-20 — review fixes: `--upload-certs` dropped from the boot-time
  `kubeadm init`; the `KubeletConfiguration` is recorded as cluster-wide
  through the `kubelet-config` ConfigMap; all four version pins are
  declared here; `control_plane_count` gains a `validation` block; the
  size band is split per template.
