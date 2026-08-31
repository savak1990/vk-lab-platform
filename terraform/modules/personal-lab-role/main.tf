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
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = module.github_oidc_trust.json
  # AWS default is 3600s - full-up/full-down can run close to or over an
  # hour, and an assumed-role session expiring mid-job fails the run with
  # ExpiredToken partway through Terraform apply/destroy, not cleanly.
  max_session_duration = 14400
}

# ADR 0022 originally hand-enumerated every action per service ("exact,
# auditable, safe to commit publicly"). In practice this meant one silent
# gap per apply attempt against a real account - a missing Describe/List/Get
# action Terraform's own providers or upstream modules call internally,
# never knowable ahead of time without a live run (ssm:GetParameter for the
# EKS AMI lookup, logs:DescribeLogGroups, several more never hit yet).
# Switched to broad per-service Allows for everything except IAM and
# Route53, with the security guarantee moved to explicit Deny statements
# instead of the Allow list's own narrowness - a Deny always overrides any
# Allow, so it can't be silently widened by a future action addition the way
# an enumerated list's omissions could. IAM and Route53 stay narrow: IAM
# because over-broad iam:* is a privilege-escalation surface (this role
# could grant itself anything), Route53 because "never touch the parent/
# root zone" is a hard constitution invariant, not just a convenience gap.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "CallerIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  # This project's own dedicated state bucket - not shared with CI (a
  # different PROJECT_NAME gets its own bucket entirely, constitution §11),
  # so no prefix restriction is needed to keep environments apart.
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    sid       = "StateBucketObjects"
    actions   = ["s3:*"]
    resources = ["${local.bucket_arn}/*"]
  }

  # The actual safety guarantee for the state bucket - not the Allow list's
  # narrowness above. Bucket-level actions (bare ARN, no /* suffix): can't
  # delete the bucket or weaken/remove its own protections.
  statement {
    sid    = "DenyStateBucketDestruction"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketAcl",
      "s3:PutBucketVersioning", "s3:PutLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock", "s3:PutEncryptionConfiguration",
    ]
    resources = [local.bucket_arn]
  }

  statement {
    sid = "Eks"
    actions = [
      "eks:*",
    ]
    resources = [
      "arn:aws:eks:${local.region}:${local.account}:cluster/${var.cluster_name}",
      "arn:aws:eks:${local.region}:${local.account}:nodegroup/${var.cluster_name}/*/*",
      "arn:aws:eks:${local.region}:${local.account}:addon/${var.cluster_name}/*/*",
      "arn:aws:eks:${local.region}:${local.account}:access-entry/${var.cluster_name}/*",
      "arn:aws:eks:${local.region}:${local.account}:podidentityassociation/${var.cluster_name}/*",
    ]
  }

  # EC2 doesn't support ARN-based resource scoping for most actions (a
  # well-known IAM limitation, not an oversight) - Resource "*" either way,
  # so a wildcard action list costs nothing in scoping precision.
  statement {
    sid       = "Ec2"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # Discovery/list actions with no cluster-scoped ARN form (unlike the Eks
  # statement above) - confirmed live, DescribeAddonVersions denied under the
  # cluster/addon-scoped statement.
  statement {
    sid = "EksDiscovery"
    actions = [
      "eks:DescribeAddonVersions", "eks:DescribeAddonConfiguration",
      "eks:ListClusters", "eks:ListAddons", "eks:ListNodegroups",
      "eks:DescribeClusterVersions",
    ]
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

  # argo-up.sh/argo-down.sh's `aws eks update-kubeconfig --role-arn` bakes a
  # chained sts:AssumeRole into the kubeconfig (this role assuming
  # eks-access-identity) - confirmed live, denied without this. Distinct from
  # the read-only statement above: this is the actual role-chaining grant.
  statement {
    sid       = "AssumeEksAccessIdentity"
    actions   = ["sts:AssumeRole"]
    resources = [data.aws_iam_role.eks_access_identity.arn]
  }

  # EKS/AutoScaling validate their own service-linked roles' existence before
  # CreateNodegroup/CreateCluster - AWS-owned roles under a fixed path, never
  # named cluster_name-*. Read-only, wildcard-scoped: GetRole on an AWS-owned
  # SLR isn't a privilege-escalation surface, unlike the PlatformIamRoles
  # statement above.
  statement {
    sid       = "ServiceLinkedRolesReadOnly"
    actions   = ["iam:GetRole"]
    resources = ["arn:aws:iam::${local.account}:role/aws-service-role/*"]
  }

  # The eks_managed_node_group submodule looks up the recommended AMI via
  # this AWS-owned public parameter (no account ID in its ARN) instead of a
  # pinned AMI ID - kept narrow (unlike the rest of this policy) since it's
  # the one SSM access this role has at all; no reason to open Parameter
  # Store more broadly for a single, known, read-only lookup.
  statement {
    sid       = "EksAmiSsmParameter"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.region}::parameter/aws/service/eks/optimized-ami/*"]
  }

  statement {
    sid       = "CloudWatchLogs"
    actions   = ["logs:*"]
    resources = ["*"] # Describe/List actions don't support resource scoping - confirmed live
  }

  # Route53 zone IDs aren't known until Terraform creates them, and this
  # policy is committed before that first apply - so, like the EC2 Create*
  # actions above, these can't be scoped to a specific hostedzone ARN. The
  # real scoping here is by action set, not by zone: this role can list/read
  # any zone, and can only write records (never create/delete a zone) in
  # whichever zone isn't the one it manages itself. NOT broadened to
  # route53:* like the other services above - a wildcard here would grant
  # DeleteHostedZone on the parent/root zone too, violating the constitution's
  # "never manage the parent/root hosted zone" invariant.
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
    sid       = "Acm"
    actions   = ["acm:*"]
    resources = ["*"] # certificate ARN includes a random ID assigned at creation, unknown ahead of time
  }

  statement {
    sid       = "SecretsManager"
    actions   = ["secretsmanager:*"]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account}:secret:${var.project}-*"]
  }

  statement {
    sid       = "SecretsManagerRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"] # not a resource-scoped action
  }

  # Broadened from just Decrypt/Encrypt (still scoped to this one key's ARN,
  # never any other key in the account) - the actual "never destroy the
  # Bootstrap KMS key" guarantee is the explicit Deny below, not this list's
  # narrowness.
  statement {
    sid       = "KmsSecretsKey"
    actions   = ["kms:*"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]
  }

  statement {
    sid       = "DenyBootstrapKmsKeyDestruction"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:DeleteImportedKeyMaterial"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]
  }

  # aws_kms_alias isn't itself scoped by the key's own ARN in IAM (aliases
  # are a separate resource type) - denied globally since this role has no
  # legitimate reason to delete any alias, and a deleted alias would orphan
  # secret-decrypt.sh's alias-based lookup even if the key itself survives.
  statement {
    sid       = "DenyKmsAliasDeletion"
    effect    = "Deny"
    actions   = ["kms:DeleteAlias"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
