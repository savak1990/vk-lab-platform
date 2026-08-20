data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  # Excludes Local Zone / Wavelength subnets some accounts' default VPCs
  # include but that EKS control planes can't use.
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Node group pinned to one deterministic subnet/AZ so a future recreate
# doesn't wander AZs and strand later specs' AZ-locked EBS volumes elsewhere.
locals {
  node_subnet_id = sort(data.aws_subnets.default.ids)[0]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0" # 21.0.0 has a `length(null)` bug in its encryption_config handling; this patch fixes it

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids # control plane: all AZs (EKS requires >= 2)

  endpoint_public_access  = true
  endpoint_private_access = false # default VPC has no private connectivity path

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # This platform uses EKS Pod Identity for workload IAM, not IRSA. IRSA
  # needs an OIDC provider registered with a TLS root-CA thumbprint; Pod
  # Identity needs neither, so IRSA is deliberately left off.
  enable_irsa = false

  # No dedicated KMS key for Kubernetes Secret envelope encryption: etcd is
  # already encrypted at rest by AWS regardless, and real secrets live in
  # Secrets Manager (spec 002), not Kubernetes Secrets. Skips the key's
  # ongoing cost and the 7-30 day pending-deletion window it would leave
  # behind after every `disposable-down`.
  create_kms_key    = false
  encryption_config = null

  # No control-plane log types shipped to CloudWatch Logs by default (the
  # module defaults to audit/api/authenticator). Ongoing CloudWatch
  # ingestion/storage cost this spec doesn't ask for; revisit alongside the
  # observability stack spec if control-plane logs are needed.
  enabled_log_types = []

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    # DaemonSet all later aws_eks_pod_identity_association resources route
    # through (Argo CD, Karpenter, AWS LB Controller land in later specs).
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      subnet_ids     = [local.node_subnet_id] # single fixed AZ, not all defaults
      labels         = { "node-type" = "system" }
    }
  }

  # IAM: relies on the module's default create_iam_role = true path for
  # both cluster and node group roles, which attaches managed policies via
  # per-policy aws_iam_role_policy_attachment resources.
}
