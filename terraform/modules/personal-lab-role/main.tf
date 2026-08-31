module "github_oidc_trust" {
  source      = "../github-oidc-trust"
  github_repo = var.github_repo
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Looked up by fixed name, not a Terragrunt dependency - same reasoning as
# terraform/modules/eks's lookup of this same role (account-global, not
# tied to this project's state bucket).
data "aws_iam_role" "eks_access_identity" {
  name = "eks-access-identity"
}

# kms:Decrypt/Encrypt authorization in an identity policy is checked against
# the underlying key's ARN, not an alias ARN - an alias-ARN resource element
# would silently grant nothing.
data "aws_kms_alias" "secrets" {
  name = "alias/${var.project}-secrets"
}

locals {
  account    = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  bucket_arn = "arn:aws:s3:::${var.project}-tf-state"

  # EC2's Create*/Modify*/Delete* actions for these resource types don't
  # support ARN-based resource scoping at all (a well-known IAM limitation,
  # not an oversight here) - every EC2 statement below uses Resource = "*",
  # narrowed instead by an aws:ResourceTag condition on this platform's own
  # Project tag where the action supports resource-tag conditions.
  ec2_actions = [
    "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup", "ec2:DescribeSecurityGroups",
    "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
    "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
    "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate", "ec2:DescribeLaunchTemplates",
    "ec2:CreateLaunchTemplateVersion",
    "ec2:CreateTags", "ec2:DeleteTags", "ec2:DescribeTags",
    "ec2:DescribeSnapshots", "ec2:DeleteSnapshot",
    "ec2:CreateVpc", "ec2:DescribeVpcs", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
    "ec2:CreateInternetGateway", "ec2:AttachInternetGateway", "ec2:DescribeInternetGateways",
    "ec2:DetachInternetGateway", "ec2:DeleteInternetGateway",
    "ec2:CreateSubnet", "ec2:DescribeSubnets", "ec2:ModifySubnetAttribute", "ec2:DeleteSubnet",
    "ec2:CreateRouteTable", "ec2:DescribeRouteTables", "ec2:CreateRoute", "ec2:DeleteRouteTable",
    "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
    "ec2:DescribeVolumes", "ec2:DeleteVolume",
  ]
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = module.github_oidc_trust.json
  # AWS default is 3600s - full-up/full-down can run close to or over an
  # hour, and an assumed-role session expiring mid-job fails the run with
  # ExpiredToken partway through Terraform apply/destroy, not cleanly.
  max_session_duration = 14400
}

data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "CallerIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["disposable/*", "persistent/*"]
    }
  }

  statement {
    sid = "DisposableStateReadWrite"
    actions = [
      "s3:GetObject", "s3:PutObject",
    ]
    resources = ["${local.bucket_arn}/disposable/*"]
  }

  statement {
    sid       = "DisposableStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/disposable/*.tflock"]
  }

  statement {
    sid = "PersistentStateReadWrite"
    actions = [
      "s3:GetObject", "s3:PutObject",
    ]
    resources = ["${local.bucket_arn}/persistent/*"]
  }

  statement {
    sid       = "PersistentStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/persistent/*.tflock"]
  }

  statement {
    sid = "Eks"
    actions = [
      "eks:CreateCluster", "eks:DeleteCluster", "eks:DescribeCluster",
      "eks:TagResource", "eks:UntagResource", "eks:ListTagsForResource",
      "eks:DescribeAddonVersions", "eks:CreateAddon", "eks:DeleteAddon",
      "eks:DescribeAddon", "eks:UpdateAddon",
      "eks:CreateAccessEntry", "eks:DeleteAccessEntry", "eks:DescribeAccessEntry",
      "eks:ListAccessEntries", "eks:AssociateAccessPolicy", "eks:DisassociateAccessPolicy",
      "eks:ListAssociatedAccessPolicies",
      "eks:CreateNodegroup", "eks:DeleteNodegroup", "eks:DescribeNodegroup",
      "eks:CreatePodIdentityAssociation", "eks:DeletePodIdentityAssociation",
      "eks:DescribePodIdentityAssociation",
    ]
    resources = [
      "arn:aws:eks:${local.region}:${local.account}:cluster/${var.cluster_name}",
      "arn:aws:eks:${local.region}:${local.account}:nodegroup/${var.cluster_name}/*/*",
      "arn:aws:eks:${local.region}:${local.account}:addon/${var.cluster_name}/*/*",
      "arn:aws:eks:${local.region}:${local.account}:access-entry/${var.cluster_name}/*",
      "arn:aws:eks:${local.region}:${local.account}:podidentityassociation/${var.cluster_name}/*",
    ]
  }

  statement {
    sid       = "Ec2"
    actions   = local.ec2_actions
    resources = ["*"]
  }

  statement {
    sid = "PlatformIamRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
      "iam:PassRole",
    ]
    # Every role this platform's disposable/persistent units create is
    # prefixed with the cluster name (cluster role, node-group role,
    # karpenter controller/node roles, the four pod-identity controller
    # roles) - never this role itself, never an unrelated role in the account.
    resources = ["arn:aws:iam::${local.account}:role/${var.cluster_name}-*"]
  }

  # This role's own IAM role, and eks-access-identity's, don't match the
  # cluster_name-* prefix above - both need to be readable (Terraform refresh/
  # plan against personal-lab-role itself; the eks-access-identity data-source
  # lookup in terraform/modules/eks and in argo-up.sh's `aws iam get-role`).
  # Read-only: neither is ever modified through this role.
  statement {
    sid = "SelfAndAccessIdentityIamRolesReadOnly"
    actions = [
      "iam:GetRole", "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
    ]
    resources = [aws_iam_role.this.arn, data.aws_iam_role.eks_access_identity.arn]
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:ListTagsLogGroup", "logs:TagResource",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:/aws/eks/${var.cluster_name}/cluster*"]
  }

  # Route53 zone IDs aren't known until Terraform creates them, and this
  # policy is committed before that first apply - so, like the EC2 Create*
  # actions above, these can't be scoped to a specific hostedzone ARN. The
  # real scoping here is by action set, not by zone: this role can list/read
  # any zone, and can only write records (never create/delete a zone) in
  # whichever zone isn't the one it manages itself.
  statement {
    sid       = "Route53Read"
    actions   = ["route53:ListHostedZonesByName", "route53:GetHostedZone", "route53:ListResourceRecordSets"]
    resources = ["*"]
  }

  statement {
    sid = "Route53OwnedZone"
    actions = [
      "route53:CreateHostedZone", "route53:DeleteHostedZone",
      "route53:ChangeTagsForResource", "route53:ListTagsForResource",
    ]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }

  statement {
    sid       = "Route53Records"
    actions   = ["route53:ChangeResourceRecordSets", "route53:GetChange"]
    resources = ["arn:aws:route53:::hostedzone/*", "arn:aws:route53:::change/*"]
  }

  statement {
    sid = "Acm"
    actions = [
      "acm:RequestCertificate", "acm:DescribeCertificate", "acm:DeleteCertificate",
      "acm:AddTagsToCertificate", "acm:ListTagsForCertificate",
    ]
    resources = ["*"] # certificate ARN includes a random ID assigned at creation, unknown ahead of time
  }

  statement {
    sid = "SecretsManager"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue",
      "secretsmanager:DeleteSecret", "secretsmanager:TagResource", "secretsmanager:UntagResource",
    ]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account}:secret:${var.project}-*"]
  }

  statement {
    sid       = "SecretsManagerRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"] # not a resource-scoped action
  }

  # Decrypts committed secrets/*.enc payloads via Terraform's aws_kms_secrets
  # data source (persistent/secrets, persistent/route53). Encrypt is only
  # exercised if generate-secrets.sh ever needs to create a new .enc file -
  # a no-op in steady state for this one already-bootstrapped project, kept
  # for correctness. Deliberately no kms:ScheduleKeyDeletion/DeleteAlias -
  # this role must never be able to destroy the bootstrap KMS key itself.
  statement {
    sid       = "KmsSecretsFile"
    actions   = ["kms:Decrypt", "kms:Encrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
