# ADR 0036: Hetzner as a third execution target with a kubeadm-bootstrapped control plane

> **Note (2026-09-20):** the bootstrap mechanism in this record is replaced by
> [ADR 0037](0037-k3s-bootstrap-on-hetzner.md). Cloud-init installs k3s from
> `get.k3s.io` instead of running `kubeadm init`, the datastore is embedded
> etcd, the CNI is flannel, and workers join at first boot with a
> Terraform-generated token rather than through `kubeadm join` over SSH. The
> rejection of k3s below rested on certification practice, a goal the operator
> withdrew on 2026-09-20; nothing had been implemented, so the change costs a
> specification rewrite only. Everything else in this record stands as written:
> Hetzner as a third execution target, the cost case and node shape, the
> Terraform/Argo CD ownership boundary and why it survives a self-bootstrapped
> cluster, the two-token handling, Roles Anywhere as the identity chain, the
> `hz.<root-domain>` delegation, the lifecycle classification that makes the
> control plane Disposable, and the cloud-controller-manager-before-Argo-CD
> ordering and the reason for it. One consequence below is withdrawn with the
> goal that justified it: the platform no longer specifies a separate
> kubeadm operations runbook. Spec HETZ-017 carries the rewrite.

## Status

Accepted

## Context

ADR 0027 added Civo as a second execution target. Civo sells managed
Kubernetes: `cluster-up` asks the provider for a cluster, the provider returns
a kubeconfig, and the platform's rule that Terraform owns the cloud while
Argo CD owns the cluster survives untouched, because the boundary between the
two is drawn by the provider.

Hetzner Cloud sells no Kubernetes at all. It sells servers, networks,
firewalls, volumes, load balancers and SSH keys. A Hetzner target therefore has
to answer a question neither existing target raises: what does "Terraform owns
the cloud, Argo CD owns the cluster" mean when there is no cluster until the
platform creates one?

The reason to answer it is cost and capacity. `specs/hetzner/research.md`
records the measured figures: a fixed pair of `cx33` servers with room for two
autoscaled workers gives roughly 14 GiB of usable memory at about 32 EUR per
month, rising to about 28 GiB at about 53 EUR at the ceiling. The Civo target
buys less memory for more money. The platform is an educational lab, and
constitution §15 makes low cost an explicit design constraint.

A self-bootstrapped control plane also bends three further rules. The token
handling of ADR 0030 assumes a provider token that stays outside the cluster.
The identity reasoning of ADR 0029 assumes federation is impossible on any
non-EKS target. The region constant of ADR 0024 names one AWS region and one
Civo region. Each of those needs a note; this record covers the target itself.

## Decision

**Hetzner Cloud becomes a third execution target, selected by
`PROVIDER=hetzner`, under its own project.** The project is `vk-hetzner-lab`
with subdomain `hz`, its own Terraform state bucket, its own SSM prefix, its
own delegated zone and its own IAM Roles Anywhere trust anchor. The account
layer is shared, exactly as ADR 0021 intends. Two new stack directories carry
the provider-specific Terraform: `terraform/live/persistent-hetzner/` and
`terraform/live/cluster-hetzner/`. AWS keeps Route 53, SSM Parameter Store,
KMS, the state bucket and GitHub OIDC. Hetzner replaces only the compute path.

**Terraform creates servers whose cloud-init bootstraps Kubernetes, and this
does not breach the ownership rule.** The control plane's cloud-init renders a
kubeadm configuration from instance metadata, runs `kubeadm init`, and installs
the CNI, all at the node's first boot. Worker cloud-init installs packages
only; `cluster-up` runs `kubeadm join` on each worker over SSH and fetches the
administrative kubeconfig.

The rule in `CLAUDE.md` is that Terraform and Argo CD must not manage the same
Kubernetes resource. Terraform here manages no Kubernetes resource at all. It
writes a server's boot script into `user_data` and returns when the server is
running. It creates no Kubernetes object, holds no kubeconfig, and configures
neither a Kubernetes nor a Helm provider. `ignore_changes` on `user_data` means
that editing the template never re-runs anything inside a live cluster. The
cluster is created by the node's own first boot, which is the node's work, not
Terraform's. This is the bootstrap driver decision recorded in the Hetzner
planning package, taken on 2026-09-20.

The alternative readings were both worse. A script that runs `kubeadm init`
over SSH needs five round trips and puts the initialization output in the
operator's terminal. Generating the cluster CA in Terraform and passing it
through `user_data` puts a private key into Terraform state and into instance
metadata, which any pod on the host network can read.

**`argo-up` installs the Hetzner cloud controller manager with Helm, before
Argo CD, and that release joins the untracked bootstrap class.** The mechanism
is specific, and stating it loosely invites a wrong fix later.

When the kubelet starts with an external cloud provider configured, the
*kubelet* adds the taint `node.cloudprovider.kubernetes.io/uninitialized` to
its own Node object at registration. The cloud controller manager removes that
taint once it has matched the Node to a server and set the provider
identifier. The taint does not stop everything: the network proxy tolerates
every taint, and the controller manager itself tolerates this one so that it
can bootstrap. What the taint does stop is cluster DNS, because the DNS
deployment kubeadm generates tolerates only the critical-addon and
control-plane taints.

Argo CD needs cluster DNS to reach its own repository server and GitHub.
Therefore Argo CD cannot be the component that installs the controller that
makes DNS possible. `argo-up` installs it directly with Helm and waits for the
taint to clear. `CLAUDE.md` already exempts the Argo CD installation itself
from Argo ownership, for the same bootstrap reason recorded in ADR 0012; this
release joins that same class. Everything else in the cluster, including the
CSI driver, belongs to Argo CD.

**The control plane is Disposable.** `make down` destroys it with the rest of
the cluster, and `make up` builds a new one. The Hetzner network and the SSH
key are Persistent. The Roles Anywhere trust anchor, profile and roles are
Bootstrap. Constitution §3's taxonomy applies unchanged; Hetzner gets no
exemption from it. A platform-owned control plane is not a reason to keep a
cluster alive, and treating it as one would defeat the point of a disposable
lab.

**The in-cluster provider token is dedicated, and its Secret has one name
across non-EKS targets.** The controller manager and the CSI driver both read
a Hetzner token from inside the cluster, so unlike Civo's operator token, a
Hetzner token must exist there. It is not the operator's token. It is a second
token in the same project, created for in-cluster use only, with its own
committed ciphertext file. Revoking it does not lock the operator out, and
revoking the operator's does not break the cluster. This preserves the
trust-boundary reasoning ADR 0030 already applies to the Civo autoscaler's
separate key, rather than making an exception to it. The Secret is
`kube-system/cloud-operator-secret` on every non-EKS target. See the amendment
note on ADR 0030 for the handling rules.

**Resource labels satisfy constitution §16 in full.** Every `hcloud_*` resource
carries `project`, `scope`, `lifecycle` and `managed_by`. Civo's tagging is
best-effort because Civo accepts only a flat string; Hetzner accepts a key and
value map, so the Hetzner target meets §16 as written, and the constitution's
§20 table says so.

**Alternatives considered:**

- **The `kube-hetzner` Terraform module.** Rejected. It installs Helm charts
  from Terraform, which is precisely the ownership boundary this platform
  keeps.
- **The standalone Hetzner Kubernetes installer.** Rejected. It keeps no
  Terraform state, so the servers it creates are invisible to the lifecycle
  commands and to the leak sweep.
- **Nodes without a public IPv4 address.** Rejected. SSM Parameter Store has no
  endpoint reachable without one, and Hetzner offers no managed address
  translation. One address per node costs 0.50 EUR per month.
- **IAM OIDC federation instead of Roles Anywhere.** Rejected for now, and
  recorded as the documented alternative in the note on ADR 0029. It is
  genuinely possible on a self-managed control plane, unlike on Civo, but
  adopting it discards six finished Civo specs and leaves the two non-EKS
  targets on different identity mechanisms.
- **k3s instead of kubeadm.** Rejected. The lab's secondary purpose is
  certification practice against the tool the exam uses.

## Consequences

- A `PROVIDER=hetzner` run touches no AWS/EKS and no Civo compute resource, and
  neither of those runs touches Hetzner. The three targets share the account
  layer, the AWS control plane services and the GitOps tree, nothing else.
- The platform now owns a Kubernetes control plane, including its upgrades,
  its certificates and its etcd backups. That work is real and is specified
  separately as an operations runbook.
- A failed first boot is diagnosed over SSH by reading the cloud-init status
  and the kubelet journal. The join step prints both on timeout.
- The catalogue facts in this record are dated. Hetzner has removed API fields
  and deprecated server types within the last year, and the controller manager
  crashes against the current API below version 1.30.1. Pin the chart version,
  never track a floating image tag, and re-verify the catalogue rather than
  trusting this record's figures indefinitely.
- Hetzner volumes support neither snapshots nor cloning, and Hetzner takes no
  backups of them. PostgreSQL persistence therefore uses the same
  object-store mechanism the Civo target uses, for the same reason.
- A Hetzner firewall attaches to servers only, never to a load balancer. A
  load balancer is reachable on its configured listener ports and cannot be
  restricted at the provider layer. Restriction, where needed, happens inside
  the cluster.

## Related

- [ADR 0027](0027-civo-second-execution-target.md) — the second target, whose
  stage model this record reuses.
- [ADR 0012](0012-argo-cd-script-bootstrap-and-cascade-teardown.md) — why the
  Argo CD installation is script-owned, and the class this controller release
  joins.
- [ADR 0021](0021-account-scoped-terraform-layer.md) — the shared account layer
  a third project reuses without new IAM.
- [ADR 0029](0029-rolesanywhere-offline-ca.md) and
  [ADR 0030](0030-civo-api-token-handling.md) — both carry notes for this
  target.
- Specs HETZ-025, HETZ-030, HETZ-035, HETZ-037, HETZ-040 and HETZ-045
  implement what this record decides.
