# ADR 0037: k3s bootstraps the Hetzner control plane, replacing kubeadm

## Status

Accepted

## Context

ADR 0036 made Hetzner Cloud a third execution target and chose kubeadm to
bootstrap its control plane. Everything in that record about the target itself —
the cost case, the node shape, the ownership boundary, the identity chain, the
DNS delegation, the lifecycle classification — was decided on its own merits and
still holds. The bootstrap mechanism was not. It rested on one sentence:

> **k3s instead of kubeadm.** Rejected. The lab's secondary purpose is
> certification practice against the tool the exam uses.

On 2026-09-20 the operator withdrew that secondary purpose and asked for the
solution with the least code, the least operational work, and no licence cost.
The only argument for kubeadm was the one that lapsed, so the decision is
re-taken here rather than left standing on a premise that no longer exists.

The timing matters. The Hetzner package is specified in detail and implemented
nowhere: no `terraform/live/cluster-hetzner`, no `hcloud-*` module, no
cloud-init template, no `scripts/hetzner-bootstrap.sh` on any branch. What
exists is about 57 lines of Make and shell dispatch and a KMS-encrypted token.
Changing the bootstrap now costs a specification rewrite; changing it after
implementation would cost the implementation too.

The kubeadm design was measured against that unwritten code. It needs roughly
1,100 lines, of which about 370 carry most of the failure modes: two cloud-init
templates that cannot share their package section, an apt repository and
keyring for `pkgs.k8s.io`, a pinned `containerd.io` with a hand-written
`SystemdCgroup` configuration, `apt-mark hold` on four packages, a kubeadm
v1beta4 document with four embedded configuration kinds, and a worker join that
mints a token on the control plane over SSH and replays it to each worker over
SSH. That join step is also why the cluster autoscaler needed a spec of its own
to mint a long-lived token, hash the cluster CA, and re-render a cloud-init
template into a Secret.

Two facts about k3s decide the rest. It is a CNCF-certified Kubernetes
distribution, so the API, the CRDs, the Helm charts and every Argo CD
Application in `gitops/` behave identically; and this platform already runs on
it, because Civo managed Kubernetes is k3s
(`terraform/modules/civo-k8s/main.tf`).

## Decision

**Cloud-init installs k3s from `get.k3s.io` on both roles.** Terraform renders
`user_data` and creates servers, exactly as ADR 0036 describes. It still creates
no Kubernetes object, holds no kubeconfig and configures no Kubernetes or Helm
provider, so the ownership boundary that record draws is unchanged.

**Terraform generates the join token** as a `random_password` and injects it
into both roles' `user_data`. The control plane starts with it; workers start
with it and with `K3S_URL` pointing at the control plane's private address. The
agent service retries until the control plane answers, so both servers are
created at once and boot order does not matter. There is no SSH in the create
path, no operator step, and no separate credential for autoscaled nodes — they
boot the same rendered worker `user_data`.

**The datastore is embedded etcd**, through `--cluster-init`, not the SQLite
default. It is one flag. It provides snapshot and restore, it makes
`--etcd-expose-metrics` meaningful so the observability spec gains a real scrape
target, and it keeps a later HA decision additive: a SQLite cluster cannot
become HA without re-initialising.

**The CNI is flannel**, k3s's default, bound to the private NIC. Nothing in
`gitops/` references Cilium. Flannel runs VXLAN, so the cloud controller manager
keeps `HCLOUD_NETWORK_ROUTES_ENABLED=false` — the same setting the Cilium VXLAN
design needed. Pod and service CIDRs become the k3s defaults, `10.42.0.0/16` and
`10.43.0.0/16`. `--flannel-backend=none` remains the documented route to another
CNI if network policy is wanted later.

**Three bundled components are disabled**, with `--disable=servicelb,traefik,`
`local-storage`. This leaves the hcloud cloud controller manager as the only
LoadBalancer controller and `hcloud-volumes` as the only default StorageClass,
which is what the ingress and GitOps specs assume. The fourth, metrics-server,
is kept: k3s ships it, so the platform no longer installs one of its own and no
longer needs `--kubelet-insecure-tls`.

**The control plane stays schedulable** and carries workloads, so the kubelet
reservations decided for the kubeadm design are carried over unchanged —
*(Amended 2026-09-24 by spec HETZ-178: it no longer does. The control plane is
created on a smaller server type and tainted
`node-role.kubernetes.io/control-plane=true:NoSchedule` at first boot. The
reservations below are unchanged and still apply to every node.)* —
`system-reserved` 500m/1Gi, `kube-reserved` 250m/512Mi, `eviction-hard`
`memory.available<300Mi`. Their distribution changes: kubeadm set them once in
the `kube-system/kubelet-config` ConfigMap and every join inherited them, while
k3s takes them as `--kubelet-arg` on each node's install line. One Terraform
variable renders both templates, so the values cannot drift apart.

**The cloud controller manager still runs before Argo CD**, for the reason
ADR 0036 gives and this change does not alter. Under `cloud-provider=external`
the kubelet taints its node `node.cloudprovider.kubernetes.io/uninitialized`;
k3s's bundled CoreDNS does not tolerate that taint; Argo CD needs cluster DNS to
reach its own repository server. So `argo-up` helm-installs the controller
manager first, and it joins Argo CD in the untracked bootstrap class.

**Alternatives considered:**

- **kubeadm.** The superseded choice. Its remaining merit was certification
  practice against the exam's tool, and that goal is withdrawn. Nothing else
  favoured it: it costs about three times the code, adds package pinning and a
  container runtime configuration the platform would own, and needs an
  out-of-band join step that a second spec existed only to serve.
- **kOps.** Free and actively maintained, with a native Hetzner provider — but
  that provider is beta, and kOps would create the network, firewall and load
  balancer that Terraform owns here, replacing the whole `cluster-hetzner`
  stack and leaving the lifecycle guards and the leak sweep nothing to bind to.
  Public reports of clusters that never formed on this provider are recent
  enough to matter.
- **The `kube-hetzner` Terraform module** and **the `hetzner-k3s` CLI.** Both
  already rejected in ADR 0036, for reasons this change does not touch: the
  first installs Helm charts from Terraform, and the second keeps no Terraform
  state. The `kube-hetzner` module additionally requires a Packer image build
  before any apply.
- **Talos Linux.** The cleanest long-term design, with an official Hetzner
  image. Rejected for now: etcd still needs a `talosctl bootstrap` call from the
  operator's machine, which is the operator step this decision removes, and it
  introduces a second toolchain and no SSH access to a node.
- **Cluster API Provider Hetzner.** Free and generally available, but it needs a
  management cluster to exist first and installs no CNI, controller manager or
  CSI driver of its own. It is built for fleets.
- **OKD.** Free and installable on Hetzner through community tooling, but a
  single-node control plane costs roughly 128 EUR per month and a three-node one
  roughly 369 EUR, against constitution §15 and a 50 to 100 USD ceiling. Its own
  community tooling warns that Hetzner storage does not meet etcd's latency
  requirements.
- **Cloud Foundry Container Runtime, VMware Cloud PKS, and Vagrant.** Examined
  and dismissed on facts: the first was archived in 2022 and has no Hetzner BOSH
  CPI; the second no longer exists as a product and its successors are
  proprietary with no Hetzner support; the third is a VM wrapper whose only
  Hetzner plugin was abandoned in 2020, and it would still run kubeadm inside
  the VM.

## Consequences

- The join token is in Terraform state and in both servers' instance metadata,
  readable by any `hostNetwork` pod at `169.254.169.254/hetzner/v1/userdata`.
  ADR 0036's design deliberately avoided putting a credential there. Half that
  objection lapses — k3s derives the cluster CA from the token, so no CA private
  key enters state — and half stands. The exposure is bounded: the token grants
  node join and nothing else, the join path is the private network, the token is
  regenerated on every `make up` and dies with the cluster, and `k3s token
  rotate` exists. A pod that can read it is already running on a cluster node.
- The platform still owns a control plane, but owns much less of it. There is no
  apt repository, no container runtime configuration and no certificate renewal
  procedure of its own; a version change is one variable and a `make down` then
  `make up`, because the cluster is Disposable. The separate operations runbook
  that ADR 0036's consequences promised is withdrawn with the goal that
  justified it.
- k3s bundles components this platform owns elsewhere. Three are disabled by
  flag. A future k3s release that adds a fourth would install it silently, so
  the disable list is verified against the release notes at every version bump,
  and the GitOps render check keeps asserting that the platform defines no
  StorageClass of its own.
- Every node runs one `k3s` process instead of static pods plus a systemd
  kubelet. Diagnosing a failed boot is `cloud-init status --long`,
  `journalctl -u k3s` or `journalctl -u k3s-agent` over SSH.
- Pod and service CIDRs move to k3s's defaults. Both stay clear of the
  `10.0.0.0/16` private network.
- ADR 0036 stands otherwise. This record replaces its bootstrap mechanism only,
  and carries a dated note there saying so.

## Related

- [ADR 0036](0036-hetzner-kubeadm-third-execution-target.md) — the Hetzner
  target; this record replaces its bootstrap mechanism.
- [ADR 0030](0030-civo-api-token-handling.md) — the in-cluster provider token,
  unchanged by this record.
- [ADR 0012](0012-argo-cd-script-bootstrap-and-cascade-teardown.md) — why the
  cloud controller manager and Argo CD are installed by a script.
- `specs/hetzner/017-D-k3s-bootstrap-governance/spec.md` — the package rewrite
  this record authorises.
