# Disposable stack

Creates Disposable-lifecycle resources: destroyed by `make disposable-down`,
recreated by `make disposable-up`, with zero effect on the Persistent stack
(Route 53 zone/ACM cert/Secrets Manager) or the AWS account's default VPC.

Two units:

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

**Deviation from `docs/architecture.md` §5's illustrative target tree:**
that diagram shows three separate units (`eks/`, `eks-addons/`,
`system-node-group/`). This stack uses a single `eks/` unit instead —
cluster, node group, add-ons, and IAM are created together, since one fixed
node group doesn't need independent apply/destroy of those pieces yet.
`karpenter/` remains a separate future unit (spec 006).

## Usage

```
make disposable-up        # terragrunt apply, all units in this stack
make disposable-down      # terragrunt destroy, all units in this stack
make eks-kubeconfig        # points local kubectl at the cluster
```

No `make up`/`make down` composite orchestration exists yet (spec 014) —
these targets are applied/destroyed directly for now. No guard script
verifies the Persistent stack exists first; that check is the future
composite `make up`'s job (constitution §17), not this stack's own targets.

Cluster access comes from `enable_cluster_creator_admin_permissions`, which
binds cluster-admin to whichever principal ran `terragrunt apply` — this
will need re-examination once CI applies this stack (specs 015/018).
