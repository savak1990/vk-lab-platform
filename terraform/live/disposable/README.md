# Disposable stack

Creates Disposable-lifecycle resources: destroyed by `make disposable-down`,
recreated by `make disposable-up`, with zero effect on the Persistent stack
(Route 53 zone/ACM cert/Secrets Manager) or the AWS account's default VPC.

Three units:

- `eks/` — EKS control plane, one fixed-size system managed node group
  (single `t3.medium`), EKS-managed add-ons (`vpc-cni`, `kube-proxy`,
  `coredns`, `eks-pod-identity-agent`), and the IAM roles the cluster/node
  group need. Runs in the AWS account's **default VPC**, using its default
  public subnets — no dedicated VPC exists yet. See
  `specs/003-network-and-eks/spec.md`.
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
make disposable-up        # terragrunt apply, all units in this stack
make disposable-down      # terragrunt destroy, all units in this stack
make eks-kubeconfig        # points local kubectl at the cluster
```

No `make up`/`make down` composite orchestration exists yet (spec 015) —
these targets are applied/destroyed directly for now. No guard script
verifies the Persistent stack exists first; that check is the future
composite `make up`'s job (constitution §17), not this stack's own targets.

Cluster access comes from `enable_cluster_creator_admin_permissions`, which
binds cluster-admin to whichever principal ran `terragrunt apply` — this
will need re-examination once CI applies this stack (specs 016/018).
