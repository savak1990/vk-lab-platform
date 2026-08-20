# ADR 0008: EBS CSI driver, Retain storage contract, and volume rebind procedure

## Status

Accepted

## Context

Spec 005 (storage contract) is the linchpin persistence-safety spec: every
later stateful workload (007-postgres, 008-kafka) trusts that a
Kubernetes-backed persistent volume genuinely survives EKS destruction and
recreation. Nothing storage-related existed in the repo before this spec —
no EBS CSI driver, StorageClass, sync wave, or IAM/pod-identity association.

Two decisions needed recording before implementation, because both are the
kind CLAUDE.md requires documenting rather than deciding silently: how the
driver is installed, and where its controller IAM lives.

## Decision

**Install the EBS CSI driver via Argo CD (Helm chart), not the EKS-managed
addon, even though CLAUDE.md's "AWS-managed EKS add-ons may be managed
through Terraform" carve-out would technically allow the addon, and even
though the managed addon is the generally-preferred choice in production EKS
setups** (AWS patches CVEs, version compatibility is validated against the
control plane, one less Argo Application to own).

Spec 005's whole purpose is to prove the reclaim/rebind contract, and the
managed addon would weaken that proof: Req 5 requires Argo installation
specifically so the driver participates in Argo's sync-wave ordering, and
CLAUDE.md requires a controller to remain running until the resources it
manages have completed cleanup. A Terraform-owned addon sits outside Argo's
dependency graph and cannot honor that ordering during `make down`. This is
a scoped decision, not a blanket rule against managed addons: add-ons with
no Argo ordering dependency and not under test (`vpc-cni`, `coredns`,
`kube-proxy`) correctly stay on the managed-addon path already used in the
`eks` Terraform module. The cost accepted here: chart-version bumps and
EKS-version compatibility for the EBS CSI driver become this repo's own
responsibility instead of AWS's.

**Controller IAM (role, policy attachment, `aws_eks_pod_identity_association`)
lives in the Disposable lifecycle**
(`terraform/live/disposable/ebs-csi-pod-identity/`), not Persistent. Lifecycle
class here is assigned by destroy cadence and blast radius, not by subject
matter — the role being "about EBS" does not make it Persistent data. Test
applied: does anything break if this role is destroyed and recreated on
every `make up`? No — it holds no state, costs nothing, and its trust policy
trusts the `pods.eks.amazonaws.com` service principal rather than a
cluster-specific OIDC provider, so it is not cluster-coupled. The pod
identity association itself is forced Disposable regardless, since it
references the cluster, which only exists in that lifecycle.

If the `gp3` volumes are ever encrypted with a customer-managed KMS key
(rather than an AWS-managed key or no encryption), that key's policy would
reference this role as a principal, and destroy/recreate of the role could
leave the KMS policy pointing at a stale principal ID. If a CMK is
introduced, this role should move to Bootstrap ("foundational IAM") instead
of Disposable — that would be a deliberate lifecycle-class move requiring its
own note, not a silent one.

**One StorageClass** (`ebs-retain`): `gp3`, `reclaimPolicy: Retain`,
`allowVolumeExpansion: true`, `volumeBindingMode: WaitForFirstConsumer`, no
default-class annotation. A Delete-based scratch class was considered and
rejected — nothing in the repo needs one yet, and 007/008 will name the
Retain class explicitly.

**Rebind procedure**: documented and exercised in
`tests/manifests/005-storage-contract/README.md`, not duplicated here. In
short — after a PVC delete the released PV does not rebind as-is (stale
`claimRef`), and after a full cluster destroy the PV object is gone entirely;
the only procedure that works for both is hand-writing a fresh PV pointing
at the retained volume's `volumeHandle`, with `nodeAffinity` pinning its AZ,
then binding a new PVC to it via `spec.volumeName`. 007/008 must follow this
exact procedure for real Postgres/Kafka volumes.

## Ownership gap this decision creates

The retained EBS volume itself is a **Persistent-lifecycle resource that no
Terraform stack owns** — it is created by a Disposable, Argo-owned
controller, and survives `make down` solely because of the StorageClass's
reclaim policy, not because any Terraform state tracks it. This is a new
pattern being introduced here, not a lifecycle-class move of an existing
resource, per CLAUDE.md's rule on documenting such changes.

The `ebs-retain` StorageClass tags every volume it provisions
(`tagSpecification_1..4`: `Project`, `Scope`, `Lifecycle=persistent`,
`ManagedBy=ebs-csi-driver`) specifically so a future "no leaks" check
(constitution's full lifecycle acceptance test) can distinguish an
intentionally-retained volume from an actual leak, since Terraform's
`default_tags` never reaches a CSI-created AWS resource.

Note `terraform/modules/ebs-volume/` (referenced in architecture.md's
intended repository layout) is a *different* mechanism —
Terraform-provisioned Persistent volumes, created and tracked by Terraform
state directly. Spec 005 proves the CSI-provisioned-then-retained path
instead, and 007/008 follow that path, not the `ebs-volume` module, so the
two should not be conflated later.

## Consequences

- `tests/manifests/005-storage-contract/` holds the proof manifests as plain
  `kubectl` files, not an Argo-managed workload, specifically so the proof
  can be re-run on demand (chart bumps, pre-007/008 re-verification) without
  Argo tracking or pruning throwaway test resources.
- This is the first use of `argocd.argoproj.io/sync-wave` in this repo (CSI
  driver wave `-1`, StorageClass wave `0`); 007/008's own Argo manifests
  should follow the same ordering discipline relative to this StorageClass.
- A retained EBS volume from a completed proof run must be deleted by ID as
  a manual cleanup step — it is not tracked by any Terraform state and will
  otherwise keep costing money indefinitely.
