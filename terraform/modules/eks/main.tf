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

# Separate from data.aws_subnets.default above: that one feeds the control
# plane, which needs subnets across >= 2 AZs. This one is filtered to a
# single AZ (var.availability_zone) so the node group's subnet is pinned
# there deterministically, matching the persistent postgres-volume unit's
# AZ (root.hcl's shared postgres_az) rather than wandering on recreate.
data "aws_subnets" "node" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = [var.availability_zone]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "No default-for-az subnet found in ${var.availability_zone}."
    }
  }
}

locals {
  node_subnet_id = one(data.aws_subnets.node.ids)
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
  # behind after every `cluster-down`.
  create_kms_key    = false
  encryption_config = null

  # karpenter-pod-identity also tags this same SG via a standalone
  # aws_ec2_tag (Karpenter's own discovery mechanism) - declaring it here
  # too keeps this module's own plan from treating that tag as drift to
  # remove, since the module owns the SG's full tags map.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  # No control-plane log types shipped to CloudWatch Logs by default (the
  # module defaults to audit/api/authenticator). Ongoing CloudWatch
  # ingestion/storage cost this spec doesn't ask for; revisit alongside the
  # observability stack spec if control-plane logs are needed.
  enabled_log_types = []

  addons = {
    vpc-cni = {
      before_compute = true
      # Prefix delegation reserves IPs in /28 blocks per ENI slot instead of
      # one at a time - free on AWS (ENIs/IPs aren't billed), it just raises
      # the pod-per-node ceiling on the same instance. maxPods overrides
      # below are required too - kubelet's own bootstrap-time ceiling
      # calculation doesn't know about prefix delegation unless told.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
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
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["t4g.medium"]
      capacity_type  = "ON_DEMAND"
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      subnet_ids     = [local.node_subnet_id] # single fixed AZ, not all defaults
      labels         = { "node-type" = "system" }

      # Matches the vpc-cni prefix-delegation override above - without this,
      # nodeadm still calculates max-pods from the pre-prefix-delegation
      # ENI/IP table and the ceiling stays 17 regardless of the addon change.
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 110
          EOT
        }
      ]
    }
  }

  # IAM: relies on the module's default create_iam_role = true path for
  # both cluster and node group roles, which attaches managed policies via
  # per-policy aws_iam_role_policy_attachment resources.
}
