# Disposable stack

Creates Disposable-lifecycle resources: destroyed by `make cluster-down`,
recreated by `make cluster-up`, with zero effect on the Persistent stack
(Route 53 zone/ACM cert/Secrets Manager/VPC).

Three units:

- `eks/` — EKS control plane, one fixed-size system managed node group
  (single `t3.medium`), EKS-managed add-ons (`vpc-cni`, `kube-proxy`,
  `coredns`, `eks-pod-identity-agent`), and the IAM roles the cluster/node
  group need. Runs in the platform-owned VPC (`terraform/live/persistent/vpc`,
  spec 020), using its public subnets. See `specs/003-network-and-eks/spec.md`.
- `argocd-bootstrap/` — installs Argo CD and the single root ("app-of-apps")
  Application via Helm, pointed at `gitops/` (the aws target's install path).
  Terraform touches nothing else Kubernetes-native from here on — see
  `specs/004-argocd-bootstrap/spec.md`.
- `karpenter/` — the Karpenter controller's Pod Identity role, the node
  IAM role/EKS access entry Karpenter-provisioned instances need to join,
  and discovery tags on the system node group's subnet/security group. See
  `specs/006-karpenter/spec.md`.

**Deviation from `docs/architecture.md` §5's illustrative target tree:**
that diagram shows three separate units (`eks/`, `eks-addons/`,
`system-node-group/`). This stack uses a single `eks/` unit instead —
cluster, node group, add-ons, and IAM are created together, since one fixed
node group doesn't need independent apply/destroy of those pieces yet.

### Prerequisite (once per AWS account): EC2 Spot service-linked role

Karpenter provisions workload nodes as EC2 Spot instances via `CreateFleet`,
which needs the `AWSServiceRoleForEC2Spot` service-linked role to already
exist — and, per AWS's own guidance, the calling IAM role isn't (and
shouldn't be) permitted to create it on the fly. Accounts that have used
EC2 Spot before (another Spot Fleet, an ASG mixed-instances policy, EMR,
Batch, etc.) already have it; a fresh or rarely-used account usually
doesn't. This is deliberately **not** Terraform-managed here — the role's
name is fixed by AWS (`AWSServiceRoleForEC2Spot`, one per account), so a
`resource` block would fail with `EntityAlreadyExists` on any account that
already has it, which is common enough to make that the wrong default.
Run once, safe to ignore if it errors that the role already exists:

```
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

Symptom if this is missing: Karpenter's controller logs show
`AuthFailure.ServiceLinkedRoleCreationNotPermitted` on `CreateFleet`, and
the pending pod that triggered the scale-up never gets a node.

## Usage

```
make cluster-up        # terragrunt apply, all units in this stack
make cluster-down      # terragrunt destroy, all units in this stack
make eks-kubeconfig        # points local kubectl at the cluster
```

`cluster-up` (part of `make up`/`make full-up`) runs
`scripts/require-persistent.sh` first, which fails fast if the Persistent
stack hasn't been applied yet, or if `eks-access-identity` doesn't exist yet
(`make account-up` not yet run) — both are prerequisites `eks/` depends on.

Cluster access comes from an unconditional EKS access entry granted to
`eks-access-identity` (`terraform/live/account/eks-access-identity/`, ADR
0022), not from `enable_cluster_creator_admin_permissions` (deliberately
`false` — see ADR 0022 for why binding admin to whichever principal ran
`apply` broke workstation/GitHub access equivalence).
