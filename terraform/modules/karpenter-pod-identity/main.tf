data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Controller role (Pod Identity): the permissions Karpenter itself needs to
# launch/terminate EC2 instances and manage the instance profiles it creates,
# scoped to this cluster via resource/request tag conditions throughout.

data "aws_iam_policy_document" "controller_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.controller_trust.json
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.service_account_namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.controller.arn
}

locals {
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
  account   = data.aws_caller_identity.current.account_id

  taggable_ec2_resource_arns = [
    "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
    "arn:${local.partition}:ec2:${local.region}:*:instance/*",
    "arn:${local.partition}:ec2:${local.region}:*:volume/*",
    "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
    "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
  ]
}

data "aws_iam_policy_document" "node_lifecycle" {
  statement {
    sid     = "AllowScopedEC2InstanceAccessActions"
    actions = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
    ]
  }

  statement {
    sid       = "AllowScopedEC2LaunchTemplateAccessActions"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:launch-template/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedEC2InstanceActionsWithTags"
    actions   = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
    resources = local.taggable_ec2_resource_arns

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceCreationTagging"
    actions   = ["ec2:CreateTags"]
    resources = local.taggable_ec2_resource_arns

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid     = "AllowScopedDeletion"
    actions = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }
}

data "aws_iam_policy_document" "iam_integration" {
  statement {
    sid       = "AllowPassingInstanceRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    actions   = ["iam:CreateInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    actions   = ["iam:TagInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileActions"
    actions   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account}:instance-profile/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }
}

data "aws_iam_policy_document" "eks_integration" {
  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account}:cluster/${var.cluster_name}"]
  }
}

data "aws_iam_policy_document" "resource_discovery" {
  statement {
    sid = "AllowRegionalReadActions"
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    actions   = ["iam:ListInstanceProfiles", "iam:GetInstanceProfile"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "controller" {
  source_policy_documents = [
    data.aws_iam_policy_document.node_lifecycle.json,
    data.aws_iam_policy_document.iam_integration.json,
    data.aws_iam_policy_document.eks_integration.json,
    data.aws_iam_policy_document.resource_discovery.json,
  ]
}

resource "aws_iam_role_policy" "controller" {
  name   = "controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

# Node role: the identity Karpenter-launched EC2 instances run as. No
# aws_iam_instance_profile resource — EC2NodeClass takes the role by name
# and Karpenter's own controller permissions manage the instance profile.

data "aws_iam_policy_document" "node_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKS_CNI_Policy",
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Lets Karpenter-launched instances actually register as Nodes: EKS managed
# node groups get this automatically from the eks module, but this role
# isn't a managed node group, so it needs an explicit access entry.
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

# Tag only the one subnet/security group the system node group already
# uses, not the whole default VPC: keeps Karpenter nodes in the same AZ as
# existing AZ-locked EBS volumes and avoids broadly tagging a shared resource.

resource "aws_ec2_tag" "node_subnet_discovery" {
  resource_id = var.node_subnet_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "node_security_group_discovery" {
  resource_id = var.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}
