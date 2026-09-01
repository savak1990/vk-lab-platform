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
  name = "alias/lab-secrets"
}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
  # Every project's own dedicated state bucket, whatever its PROJECT_NAME -
  # the account layer's own state bucket is named distinctly (not "*-tf-state")
  # specifically so this role never matches it.
  bucket_arn = "arn:aws:s3:::*-tf-state"
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

  # This project's own dedicated state bucket - not shared with CI. Covers
  # both bucket-level (CreateBucket, PutBucketVersioning, ...) and
  # object-level actions; no Deny on weakening protections since IAM can't
  # tell "set at creation" from "weakened later" on the same Put* call, and
  # denying them would break terraform-state's own bucket creation.
  statement {
    sid       = "StateBucket"
    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
  }

  statement {
    sid = "Eks"
    actions = [
      "eks:*",
    ]
    # "*-eks" matches any PROJECT_NAME's cluster ("<project>-eks") - no
    # per-project apply needed to grant this role a new project's cluster.
    # Region wildcarded too: this role is applied once, in account-up's own
    # region, but must authorize clusters created in any REGION a project
    # chooses - a literal ${local.region} here would silently deny every
    # other region.
    resources = [
      "arn:aws:eks:*:${local.account}:cluster/*-eks",
      "arn:aws:eks:*:${local.account}:nodegroup/*-eks/*/*",
      "arn:aws:eks:*:${local.account}:addon/*-eks/*/*",
      "arn:aws:eks:*:${local.account}:access-entry/*-eks/*",
      "arn:aws:eks:*:${local.account}:podidentityassociation/*-eks/*",
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
      # The AWS provider's aws_iam_role delete path always checks for
      # attached instance profiles first, even when none exist - confirmed
      # live, DeleteRole denied on every one of these roles at teardown.
      "iam:ListInstanceProfilesForRole",
    ]
    # Every role this platform's disposable/persistent units create is
    # prefixed with the cluster name ("<project>-eks-...": cluster role,
    # node-group role, karpenter controller/node roles, the four
    # pod-identity controller roles) - "*-eks-*", not "*-*", so this never
    # matches this role's own name or eks-access-identity's.
    resources = ["arn:aws:iam::${local.account}:role/*-eks-*"]
  }

  # Karpenter dynamically creates/owns an EC2 instance profile per
  # EC2NodeClass (name "${cluster_name}_<hash>", not the role-name prefix
  # above) via its own controller's IAM permissions, normally cleaned up by
  # its own EC2NodeClass finalizer. Confirmed live: if Karpenter's controller
  # is already torn down before that finalizer completes (e.g. an earlier
  # interrupted `make down`), the instance profile is orphaned with no
  # controller left to remove it, and Terraform's own node-role DeleteRole
  # then needs to detach/delete it directly - a distinct resource type
  # (instance-profile, not role) from the statement above, evaluated
  # separately by IAM.
  #
  # Path, not just name, matters here: Karpenter creates these under
  # "/karpenter/<region>/<cluster>/<uuid>/" - confirmed live
  # (`aws iam get-instance-profile`) - not path "/". A resource pattern
  # anchored on the name alone ("instance-profile/${cluster_name}_*") never
  # matches, since IAM's ARN path segment sits before the name; `*` does
  # cross "/" but only once matched from where it's placed in the pattern.
  # The per-EC2NodeClass UUID segment is unknowable at commit time, so this
  # is scoped by Karpenter's own path prefix instead of the full path.
  statement {
    sid       = "KarpenterOrphanedInstanceProfileCleanup"
    actions   = ["iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
    resources = ["arn:aws:iam::${local.account}:instance-profile/karpenter/*"]
  }

  # This role's own IAM role, and eks-access-identity's, don't match the
  # *-eks-* prefix above - both need to be readable (Terraform refresh/
  # plan against lab-role itself; the eks-access-identity data-source
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

  # Belt-and-suspenders alongside PlatformIamRoles' "*-eks-*" resource
  # pattern above: an explicit Deny, not just a narrower Allow, on this
  # role modifying its own permissions or eks-access-identity's - a
  # future PlatformIamRoles pattern change can't silently reopen
  # self-escalation the way a same-shaped-but-broader Allow could.
  statement {
    sid    = "DenySelfAndAccessIdentityIamRoleMutation"
    effect = "Deny"
    actions = [
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:DeleteRole", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
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
  # Store more broadly for a single, known, read-only lookup. Region
  # wildcarded: this role is applied once, in account-up's own region, but
  # a project's cluster (and its AMI lookup) can be in any region.
  statement {
    sid       = "EksAmiSsmParameter"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:*::parameter/aws/service/eks/optimized-ami/*"]
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

  # "*-secrets*" matches any PROJECT_NAME's own secret ("<project>-secrets",
  # plus Secrets Manager's random ARN suffix). Region wildcarded for the
  # same reason as the Eks/SSM statements above.
  statement {
    sid       = "SecretsManager"
    actions   = ["secretsmanager:*"]
    resources = ["arn:aws:secretsmanager:*:${local.account}:secret:*-secrets*"]
  }

  statement {
    sid       = "SecretsManagerRandomPassword"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"] # not a resource-scoped action
  }

  # Broadened from just Decrypt/Encrypt (still scoped to this one key's ARN,
  # never any other key in the account) - the actual "never destroy the
  # shared secrets KMS key" guarantee is the explicit Deny below, not this
  # list's narrowness. Unlike the state bucket above, this Deny stays
  # unconditional: the key is account-global and shared by every project's
  # secrets, so no per-project destroy should ever be able to touch it -
  # only account-down (a distinct script/role/terragrunt unit this role
  # never runs) destroys it.
  statement {
    sid       = "KmsSecretsKey"
    actions   = ["kms:*"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]
  }

  statement {
    sid       = "DenySharedKmsKeyDestruction"
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
