---
id: "HETZ-030"
title: "cluster-hetzner stack: firewall and NODE_COUNT cx33 servers that install k3s from their own cloud-init"
status: "IN_REVIEW"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "The k3s flag set is short but unforgiving: a missing --disable-cloud-controller or --kubelet-arg surfaces only at the CCM stage, and server replacement semantics and the token's placement in user_data interact with Terraform state"
effort_estimate: "One session (4–6 h) including real create/destroy cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-010", "HETZ-015", "HETZ-017", "HETZ-025"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-21"
completed: ""
---

# HETZ-030 — Hetzner cluster nodes

## 1. Outcome and rationale

`PROVIDER=hetzner make cluster-up` creates a firewall and `NODE_COUNT`
`cx33` servers in the persistent network: one control plane and
`NODE_COUNT - 1` workers, three in all by default. Each server's cloud-init
installs k3s from `get.k3s.io`. The control plane starts `k3s server` with
embedded etcd and brings itself up; each worker starts `k3s agent` against
the control plane's private address and joins as soon as the API answers.
All carry the same Terraform-generated join token. The cluster is therefore
running a minute or two after create, with no operator step and no SSH in
the create path.

The control plane counts toward `NODE_COUNT` because it is schedulable by
decision and is billed like any other server (SHARED-044 §3.3). This
supersedes the 1 + 1 fixed pool this spec was written against, and with it
the M1 placement of HETZ-170: three fixed servers leave no room for two
autoscaled ones under the four-node ceiling.

Terraform creates no Kubernetes object. It renders `user_data`, holds no
kubeconfig and configures no Kubernetes or Helm provider. HETZ-040 fetches
the kubeconfig over SSH and waits for every node to report Ready.
`cluster-down` destroys the servers and the firewall only and does not
touch the persistent units. The cloud controller manager (HETZ-045) and
everything above it are installed later.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-hetzner/{firewall,k8s}`, modules
`hcloud-firewall` and `hcloud-nodes`, both cloud-init templates, the join
token, the SSM outputs, and the hetzner arm of `cluster-down` — the token
export and the leak sweep, without which nothing this spec creates can be
destroyed by its own `make` target. Not in scope: the
kubeconfig fetch, the node-Ready wait, `cluster_exists` and
`configure_kubeconfig` (HETZ-040); the
cloud controller manager and the taint wait (HETZ-045); the CSI driver and
the storage class (HETZ-050); the autoscaler (HETZ-170); and any
Kubernetes object Terraform would own.

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
- k3s installs as a single binary and one systemd unit from
  `https://get.k3s.io`, pinned with `INSTALL_K3S_VERSION`. It embeds
  containerd, so no container runtime is installed or configured
  separately, and no apt repository or package hold is involved.
  https://docs.k3s.io/installation/configuration
- The flags that matter here: `--disable-cloud-controller` drops k3s's own
  stub controller so the hcloud one (HETZ-045) is the only cloud provider;
  `--kubelet-arg=cloud-provider=external` makes the kubelet self-taint
  `node.cloudprovider.kubernetes.io/uninitialized` until that controller
  sets a `providerID`; `--disable=servicelb,traefik,local-storage` removes
  the three bundled components the platform supplies itself;
  `--cluster-init` selects embedded etcd instead of the SQLite default;
  `--tls-san` adds the public address to the API server certificate;
  `--node-ip` and `--node-external-ip` fix the addresses the node
  advertises; `--flannel-iface` binds the CNI to the private NIC.
  https://docs.k3s.io/cli/server ; https://docs.k3s.io/networking/networking-services
- A `k3s agent` joins with `K3S_URL` and `K3S_TOKEN`. Only the short
  password-form token may be pre-set on the server before it starts, which
  is what lets Terraform generate one and put it in both renders; the
  agent's systemd unit restarts until the URL answers, so the two servers
  may be created at the same time.
  https://docs.k3s.io/cli/token ; https://docs.k3s.io/installation/configuration
- The hcloud cloud controller manager matches a node by
  `spec.providerID`, falling back to the node name against the Hetzner
  server name; the node's hostname must therefore equal the server name,
  or the fallback lookup fails.
  https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/hcloud/instances.go
- HETZ-020 confirmed the `cx33` server type string and the x86
  `ubuntu-24.04` image string with real creates on 2026-09-19, and that the
  private NIC is `enp7s0` at MTU 1450. Its 2026-09-21 re-measurement found
  `cx33` orderable in `nbg1` and `hel1` but `fsn1` out for every server
  type, which is what `scripts/lib/catalog.sh` encodes.
- The private NIC is attached by a second API call, after the server has
  begun to boot, and cloud-init reads its network configuration once. A
  server that loses that race gets an `eth0`-only netplan and the NIC then
  sits as a link in state `DOWN` that nothing configures, so `--node-ip`
  and `--flannel-iface` have no address to bind and an agent never reaches
  the API. Measured on the first real bring-up of this stack, 2026-09-21:
  the control plane won the race, both workers lost it. The templates
  therefore own the netplan stanza rather than depending on the datasource.
  `research.md`'s spike note reasoned the opposite, on a spike that created
  its servers stopped and attached them before power-on.
- decisions.md §3, row "Bootstrap mechanism" (decided 2026-09-20) and
  ADR 0037: k3s from cloud-init, embedded etcd, flannel, and a
  Terraform-generated token in `user_data`; one schedulable control plane
  plus one worker, both `cx33`; port 22 open to the world, key-only;
  control-plane metrics bound to the private address.
- research.md, "Metadata service": `169.254.169.254/hetzner/v1/metadata`
  serves the node's own `public-ipv4` without authentication, so each node
  fills its own external address at boot instead of taking it from an
  `apply`-time Terraform value. The same row records the cost of putting
  the token there: `/hetzner/v1/userdata` is readable by any process on
  the node, including a `hostNetwork` pod. ADR 0037 states the bound.

## 4. Design and contracts

Firewall (`cluster-hetzner/firewall`, module `hcloud-firewall`):

- `hcloud_firewall` named `${project}-nodes`. Rules, all `direction =
  "in"`: tcp 22 from `0.0.0.0/0` and `::/0` (GitHub runners have no fixed
  IP; password auth is off on the image); tcp 6443 from the same; icmp
  from the same. **No `out` rules.** Adding one flips outbound to
  default-deny and breaks DNS and the k3s download during cloud-init, the
  same trap CIVO-030 met with UDP/53. `apply_to { label_selector =
  "project=${project},scope=platform" }` — a label every node carries,
  including the autoscaler's, so the firewall covers autoscaled nodes
  too. Labels per HETZ-015. Writes SSM
  `/${project}/cluster-hetzner/firewall/firewall_id`.
- No rule is needed for the agent join, the flannel VXLAN tunnel
  (UDP 8472), etcd (2379/2380) or the kubelet (10250): all of it runs on
  the private network, which a Hetzner firewall does not filter. NodePorts
  need no public rule either, because the load balancer reaches nodes over
  the same private network (HETZ-060, `use-private-ip`).

Servers (`cluster-hetzner/k8s`, module `hcloud-nodes`):

- `random_password.k3s_token`, 48 characters, alphanumeric, `special =
  false`. It is in Terraform state and in both renders of `user_data`. It
  is regenerated on every `make up` and dies with the cluster, and it
  grants node join and nothing else. ADR 0037 records the exposure and its
  bounds; §12 repeats them.
- One `hcloud_server` named `${project}-cp-1`, and `${project}-worker-N`
  for each of `node_count - control_plane_count`.
  `server_type = var.node_type` (default `cx33`), `image =
  "ubuntu-24.04"`, `location = var.location` (default `nbg1`), `ssh_keys =
  [dependency.ssh_key.outputs.ssh_key_id]`, `public_net { ipv4_enabled =
  true, ipv6_enabled = true }` (IPv4 is required: SSM has no IPv6
  endpoint and Hetzner has no managed NAT), `network { network_id, ip,
  alias_ips = [] }` with the control plane at `cidrhost(subnet, 10)` and
  workers from `cidrhost(subnet, 11)` — derived, not written twice, because
  the agents' `K3S_URL` must not drift from the subnet — `labels = { project, scope = "platform", lifecycle =
  "disposable", managed_by = "terraform", role =
  "control-plane"|"worker" }`, `shutdown_before_deletion = true`.
- No `depends_on` between the roles. The agent's systemd unit restarts
  until the control plane's API answers, so creation order does not
  matter; ordering the creates would only lengthen `apply` without
  changing the outcome.
- `lifecycle { ignore_changes = [user_data, image, ssh_keys] }`.
  Rationale: a cloud-init edit or an image rename must never replace the
  control plane silently, because replacement is cluster loss. A version
  bump ships only through a `make down` then `make up`. The module records
  this in a comment.
- Variables: `node_count` and `node_type` are SHARED-044's, read in the
  unit's `inputs` with `get_env` exactly as `cluster-civo/k8s` and
  `cluster/eks` read them. The catalogue is the cost guardrail and is not
  duplicated into Terraform; the module carries only the narrow
  `node_count > control_plane_count` check.
  `k3s_version` defaults to `v1.36.4+k3s1`, the value HETZ-020 pinned
  because `cluster-autoscaler` publishes no 1.37 tag and the hcloud
  controller manager supports 1.34 to 1.36. A pin belongs in git, so it is
  a module default rather than a `TF_VAR_*` export from a new
  `scripts/lib/versions.sh` — which would also be a second mechanism beside
  the `get_env`-in-`inputs` one SHARED-044 established. It renders into
  **both** templates from the one variable: a worker on a different k3s
  version than the control plane fails to join with little explanation
  (§12).
  `control_plane_count` defaults to 1 and carries `validation { condition
  = var.control_plane_count == 1; error_message = "HA control plane needs
  a stable API address for the agents; see decisions.md" }` until an HA
  spec lifts it. The worker count is `node_count - control_plane_count`,
  not `node_count - 1`, so that validation is the only thing holding the
  arithmetic at one control plane.
- `location` is a module variable defaulting to `nbg1`. It is deliberately
  not wired to `REGION`: that input is validated and exported today but
  reaches no Terraform anywhere, and constitution §19's prohibition on
  deriving a region from the environment is unamended. SHARED-044's later
  parts own that wiring, and the variable makes it a one-line unit change.
- Two cloud-init templates under `templates/`, each a standalone
  `#cloud-config` document rendered with `templatefile()`. Both begin with
  a `write_files` that lays down `/etc/netplan/60-hcloud-private.yaml`, a
  `dhcp4` stanza for the private NIC, and a `runcmd` that waits for the
  link, runs `netplan apply`, waits for the address and fails loudly if it
  never arrives. Only then does it read the node's own public IPv4 from
  `169.254.169.254/hetzner/v1/metadata` into `$PUB` and install k3s. Owning
  the stanza is what makes the attach race in §3 harmless; an early
  `bootcmd` wait cannot, because that stage precedes network configuration.
- `templates/control-plane.yaml.tftpl`, rendered only for
  `${project}-cp-1`:

  ```
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${token} sh -s - server \
    --cluster-init \
    --disable-cloud-controller \
    --disable=servicelb,traefik,local-storage \
    --kubelet-arg=cloud-provider=external \
    --kubelet-arg=system-reserved=cpu=500m,memory=1Gi \
    --kubelet-arg=kube-reserved=cpu=250m,memory=512Mi \
    '--kubelet-arg=eviction-hard=memory.available<300Mi' \
    --node-ip=10.0.1.10 --node-external-ip=$PUB --tls-san=$PUB \
    --flannel-iface=enp7s0 --etcd-expose-metrics \
    --kube-controller-manager-arg=bind-address=10.0.1.10 \
    --kube-scheduler-arg=bind-address=10.0.1.10 \
    --write-kubeconfig-mode=0600
  ```

  `--cluster-init` selects embedded etcd, which gives snapshot and restore
  and keeps a later HA spec additive; it is also what makes
  `--etcd-expose-metrics` meaningful for HETZ-160. The three `--disable`
  values remove components the platform supplies itself: the hcloud cloud
  controller manager is the only LoadBalancer controller (HETZ-060) and
  `hcloud-volumes` is the only default StorageClass (HETZ-050).
  metrics-server is deliberately **not** disabled — k3s ships it, so the
  platform installs none of its own. The control plane carries no taint,
  because it is schedulable by decision, so the three kubelet reservations
  keep etcd and the API server out of memory pressure when workloads fill
  the node. The scheduler, controller manager and etcd metrics bind to the
  private address only.
- `templates/node.yaml.tftpl`, rendered for every worker and read
  unchanged by HETZ-170 for autoscaled nodes:

  ```
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${token} \
    K3S_URL=https://10.0.1.10:6443 sh -s - agent \
    --kubelet-arg=cloud-provider=external \
    --kubelet-arg=system-reserved=cpu=500m,memory=1Gi \
    --kubelet-arg=kube-reserved=cpu=250m,memory=512Mi \
    '--kubelet-arg=eviction-hard=memory.available<300Mi' \
    --node-ip=$PRIV --node-external-ip=$PUB \
    --flannel-iface=enp7s0
  ```

  An agent has no `kubelet-config` ConfigMap to inherit, unlike a
  `kubeadm join`, so the reservations are repeated here from the same
  Terraform variables. `$PRIV` is read at boot from
  `169.254.169.254/hetzner/v1/metadata/private-networks`, not substituted
  by Terraform, so **one render fits every worker**: the fixed worker and
  any node the autoscaler creates, whose address Terraform cannot know.
  That is what lets HETZ-170 use this render as it stands instead of
  building a second one. The node's hostname is the Hetzner server name by
  default, which is what the cloud controller manager's fallback lookup
  needs; no template sets a different one.
- Size: the render carries no apt keyring, so both templates land well
  under a kilobyte against the 32 KiB `user_data` cap. §6 step 1 measures
  them and the module asserts the bound, because HETZ-170 feeds the worker
  render to the autoscaler unchanged.
- Outputs to SSM as plain String:
  `/${project}/cluster-hetzner/k8s/control_plane_ip`,
  `/…/control_plane_private_ip`, `/…/worker_ips` (comma-separated list),
  `/…/server_ids` (comma-separated list). No kubeconfig and no private key
  material is ever an output or ever enters state.
- One further SSM parameter, `/…/worker_user_data`, as a **`SecureString`**:
  the rendered worker cloud-init, which carries the join token. HETZ-170
  feeds it to the cluster autoscaler as the node template for the nodes it
  creates, so the autoscaler does not render one of its own and cannot
  drift from the fixed workers. `SecureString` because the render holds the
  token (ADR 0023); it is the only Hetzner cluster parameter that is not a
  plain `String`. Its `--node-ip` is not substituted: the render reads the
  node's own private address at boot from
  `169.254.169.254/hetzner/v1/metadata/private-networks`, which is correct
  for a Terraform worker and for an autoscaled one alike.
- Terraform returns when every server reaches `running`, not when k3s is
  up. HETZ-040 waits for `/etc/rancher/k3s/k3s.yaml` and for every node to
  report Ready.

## 5. Files/components affected

- `terraform/live/cluster-hetzner/{firewall,k8s}/terragrunt.hcl` (new);
  `terraform/modules/hcloud-firewall`, `terraform/modules/hcloud-nodes`
  with `templates/control-plane.yaml.tftpl` and
  `templates/node.yaml.tftpl` (new); `versions.tf` pins
  `hetznercloud/hcloud` and `hashicorp/random`; lock files.
- `scripts/cluster-down.sh`: a hetzner arm. It exports the API token before
  the destroy — without it terraform refuses with "Missing Hetzner Cloud API
  token" and the servers survive their own teardown target — and sweeps for
  leaked servers and firewalls by label instead of falling through to the
  AWS arm and querying EC2 for a project that owns none.
- No `Makefile` change: the hetzner `cluster-up` arm has sourced
  `hcloud_token` and pointed at `cluster-hetzner` since HETZ-010, and
  `k3s_version` is a module default rather than an exported variable.
- No `terraform/live/root.hcl` change: `lifecycle_class` already maps
  `cluster-hetzner` to `disposable` and the `hcloud_provider` generation
  block already exists, both landed with HETZ-025. `local.hcloud_location`
  is dead code there — the location does not flow through `root.hcl`.
- No `terraform/modules/lab-role/main.tf` change: the `*/cluster-hetzner/*`
  SSM ARN and `kms:*` on `alias/lab-secrets` are both already present.
- `scripts/status.sh:59` still hardcodes the civo Terraform unit path.
  Left to HETZ-040, which owns the Hetzner script surface, to keep this
  change clear of SHARED-044's concurrent edits to `scripts/`.
- State keys `cluster-hetzner/firewall` and `cluster-hetzner/k8s` in the
  hetzner bucket.

## 6. Implementation steps

1. Write the modules and both cloud-init templates; render each with
   `terraform console`, check size and syntax with `cloud-init schema
   --config-file`, and confirm both renders carry the same
   `INSTALL_K3S_VERSION`.
2. Write the units with `dependency` blocks on
   `persistent-hetzner/{network,ssh-key}` and `cluster-hetzner/firewall`;
   mock outputs for `validate` and `plan`.
3. `terragrunt run --all plan` with `HCLOUD_TOKEN`; then `PROVIDER=hetzner
   make cluster-up`.
4. Watch the first boot over SSH (`cloud-init status --wait`, then
   `journalctl -u k3s` on the control plane and `journalctl -u k3s-agent`
   on the worker), record the time from create to both nodes registering,
   and verify the §8 checks.
5. `PROVIDER=hetzner make cluster-down`; confirm with `hcloud server
   list` and `hcloud firewall list`; confirm the network and SSH key
   remain; repeat once to prove idempotence and record timings.

## 7. Dependencies and blockers

HETZ-025 supplies the network, subnet and SSH key ids. HETZ-010 supplies
the `PROVIDER=hetzner` surface and the token helper. HETZ-015 supplies the
governance base this spec's labels depend on, and HETZ-017 the bootstrap
decision it implements. HETZ-020's image, NIC-name and timing evidence is
carried into §3 but is not a blocking dependency here. HETZ-040, which
fetches the kubeconfig and waits for Ready, can be drafted in parallel
against the SSM outputs this spec writes.

## 8. Acceptance criteria

- All `NODE_COUNT` servers reach `running` within a few minutes of `apply`.
- Over SSH on the control plane within `HETZNER_CP_BOOTSTRAP_SECONDS`
  (default 600 s) of `apply`: `cloud-init status --wait` exits 0;
  `/etc/rancher/k3s/k3s.yaml` exists; `k3s --version` prints the pinned
  `k3s_version`; `systemctl is-active k3s` prints `active`.
- `k3s kubectl get nodes` on the control plane lists every node, each
  `Ready`, each still carrying
  `node.cloudprovider.kubernetes.io/uninitialized`. CoreDNS is `Pending`
  until HETZ-045's cloud controller manager clears that taint; that is
  expected here, not a failure.
- `k3s kubectl get pods -A` shows no `traefik`, no `svclb-` and no
  `local-path-provisioner` pod, and no k3s cloud controller manager;
  `k3s kubectl get sc` lists no `local-path`. `metrics-server` is present
  and is the only one in the cluster.
- `k3s kubectl get nodes -o jsonpath='{.items[*].metadata.name}'` returns
  the Hetzner server names exactly.
- Every node's `status.addresses` carries only `InternalIP` and `Hostname`
  before the cloud controller manager runs, even though
  `--node-external-ip` is on the install line. Under
  `cloud-provider=external` the kubelet publishes no addresses of its own,
  so `kubectl get nodes -o wide` showing `EXTERNAL-IP <none>` here is the
  expected state, not a missing flag; HETZ-045 populates it.
- `k3s etcd-snapshot save` succeeds on the control plane, proving
  `--cluster-init` selected embedded etcd rather than SQLite.
- `nc -zv <cp ip> 22 6443` succeeds; `nc -zv <cp ip> 80 443 10250 30000`
  fails; `nc -zv <worker ip> 6443` fails.
- `terraform state pull | jq` shows no `kubeconfig` key and no private key
  material. The join token is present, and is the documented exposure of
  ADR 0037.
- SSM parameters exist under `/vk-hetzner-lab/cluster-hetzner/`, including
  `worker_ips`. `worker_user_data` is the only one whose `Type` is
  `SecureString`; every other is `String`.
- The `worker_user_data` parameter, decoded, is byte-identical to the
  `user_data` the fixed worker booted with, and contains no substituted
  private address.
- `PROVIDER=hetzner make cluster-down` destroys both units and reports no
  leaks. It leaves the network, subnet, and SSH key; `hcloud primary-ip
  list` is empty (server IPs are deleted with the servers).
- One create/destroy cycle costs under 0.30 EUR (three `cx33` for under an
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

- The join token is in Terraform state and in both servers' instance
  metadata, readable by any `hostNetwork` pod at
  `169.254.169.254/hetzner/v1/userdata`. It grants node join only, the
  join path is the private network, and it dies with the cluster. Accepted
  and recorded in ADR 0037; a pod that can read it is already running on a
  cluster node.
- `cx33` stock: `apply` fails with a placement error when `nbg1` is sold
  out. The module exposes `server_type` as a variable so HETZ-175's
  fallback is a tfvars change; `apply` is not retried in a loop.
- One variable renders `INSTALL_K3S_VERSION` into both templates. If a
  future change splits them, a worker on a different version fails to join
  and the log line is not obvious; §6 step 1 diffs the two renders.
- A k3s release that adds a bundled component the platform also supplies
  would install it silently. The `--disable` list is checked against the
  release notes at every version bump, and HETZ-050's render check keeps
  asserting that the platform defines no StorageClass of its own.
- Embedded etcd on a single node writes more than the SQLite default. The
  `cx33` local NVMe has headroom, but HETZ-150 records etcd write latency
  once so a later HA decision has a baseline.
- `user_data` size: both renders stay under 32 KiB, and HETZ-170 feeds the
  worker render to the autoscaler unchanged, so the module asserts the
  bound rather than trusting it.
- The image name comes from HETZ-020; if Hetzner renames it, `apply`
  fails loudly rather than booting a wrong image.
- `ignore_changes` on `user_data` means a flag fix ships only through a
  `down`/`up` cycle; accepted for a disposable cluster.
- Port 22 open to `0.0.0.0/0`, key-only: brute-force noise in `auth.log`
  is accepted, not mitigated, in M1.
- The node's hostname must equal the Hetzner server name for the cloud
  controller manager's fallback lookup (§3); a template that sets a
  different hostname breaks HETZ-045 silently until then.
- A k3s install that fails at boot is invisible to Terraform, which
  reports a healthy `running` server. It is read with `cloud-init status
  --long`, `tail -n 50 /var/log/cloud-init-output.log` and `journalctl -u
  k3s` or `journalctl -u k3s-agent` over SSH, which HETZ-040 prints when
  its wait times out.
- `control_plane_count > 1` fails at `plan` on the variable's own
  `validation` block: the worker template hardcodes `10.0.1.10` as
  `K3S_URL`, so a second control plane needs a stable address the package
  does not yet define. `--cluster-init` at least makes the later HA change
  additive.

## 13. Definition of done

- [x] Modules formatted and validated; both cloud-init templates rendered,
      parsed and size-checked against the 32 KiB cap
- [x] One real create recorded, with timings, and one real destroy with an
      empty leak sweep
- [ ] A create on the fixed templates brings every node to `Ready` with no
      manual step — blocked on Hetzner stock, see §14
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
- 2026-09-20 — option C: `kubeadm init` and the Cilium install move into
  the control plane's cloud-init.
- 2026-09-20 — rewritten for k3s (HETZ-017, ADR 0037); folder renamed to
  `030-P-hetzner-terraform-k3s-nodes`. The firewall, the server, label,
  address and SSM-output design and the `control_plane_count` validation
  survive unchanged. Gone: both apt repositories and keyrings, the
  `containerd.io` pin and its `SystemdCgroup` configuration, `apt-mark
  hold`, the kubeadm v1beta4 document, the boot-time helm and Cilium
  install and the `cp-bootstrap-done` marker. New: `random_password`
  for the join token, one `k3s_version` variable in place of four pins,
  `--cluster-init` for embedded etcd, and the kubelet reservations
  repeated on the agent because there is no `kubelet-config` ConfigMap to
  inherit. The worker template is no longer substituted by a script —
  HETZ-170 uses the Terraform render as it stands.
- 2026-09-21 — implemented; status `IN_REVIEW`, folder renamed to
  `030-A-hetzner-terraform-k3s-nodes`. Amended against two things that
  landed after the last revision. SHARED-044 made `NODE_COUNT` the operator
  input and counts the schedulable control plane in it, so the fixed pool is
  three servers and `server_type`/`worker_count` give way to
  `node_type`/`node_count`; `k3s_version` becomes a module default rather
  than a `TF_VAR_*` export from a `scripts/lib/versions.sh` that does not
  exist. HETZ-020's re-measurement removed `fsn1`. Four §5 items turned out
  to be already done by HETZ-025 and are recorded as such rather than
  repeated. `cluster-down` gained the hetzner arm it needed to destroy what
  `cluster-up` creates.
- 2026-09-21 — first real bring-up, `vk-hetzner-lab`, `nbg1`, 3 × `cx33`.
  Three servers `running` 33 s after `apply`; cloud-init `done`; k3s
  `v1.36.4+k3s1` `active`; the control plane `Ready` at 17 s with roles
  `control-plane,etcd`; both registered nodes carrying
  `node.cloudprovider.kubernetes.io/uninitialized` with an empty
  `providerID`; four plain `String` SSM parameters and `worker_user_data`
  the only `SecureString`. `make cluster-down` destroyed both units with an
  empty leak sweep, and the network and SSH key survived it.
- 2026-09-21 — and it found a real defect: **both workers never joined.**
  The private NIC is attached by a second API call after the server has
  begun to boot, and cloud-init reads its network configuration once, so
  the two servers that lost that race were left with an `eth0`-only netplan
  and a private NIC in state `DOWN` that nothing configured. Their agents
  retried the API address forever. Writing the stanza by hand on one of them
  brought up `10.0.1.11`, opened 6443, and the node was `Ready` 14 s later
  with no other change — so both templates now own the netplan stanza and
  wait for the address before installing k3s, and the early `bootcmd` wait
  is gone, having run in a stage that precedes network configuration.
- 2026-09-21 — the recreate that would prove that fix in the template could
  not run: `cx23`, `cx33` and `cx43` were all `available=false` in both
  `nbg1` and `hel1`, so every catalogue-legal shape was out of stock in the
  whole `eu-central` zone. The fix is proven on the failing node, not yet on
  a fresh `apply`. That recreate is the one open acceptance item, and it is
  the DoD's remaining box.
