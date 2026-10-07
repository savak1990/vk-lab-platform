module "github_oidc_trust" {
  source      = "../github-oidc-trust"
  github_repo = var.github_repo
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# kms:Decrypt authorization in an identity policy is checked against the
# underlying key's ARN, not an alias ARN - an alias-ARN resource element would
# silently grant nothing.
data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

locals {
  ssm_prefix                 = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter"
  root_domain_parameter_arn  = "${local.ssm_prefix}/account/root_domain"
  deploy_token_parameter_arn = "${local.ssm_prefix}/*/cluster/ahorro-deploy/token"

  # Wildcarded on the project, not on the path: one role serves every lab
  # project, and the project a run targets is its own input. Both paths stay
  # pinned to their last two segments, so widening either one is a visible
  # change here rather than a silent reach into a sibling prefix.
  deploy_credential_parameter_arn = "${local.ssm_prefix}/*/cluster/ahorro-deploy/*"

  # Named one by one rather than wildcarded, because the same prefix holds
  # test_user_password. The client reads these four and has no use for the
  # fifth.
  cognito_parameter_arns = [
    "${local.ssm_prefix}/*/persistent/ahorro-cognito/user_pool_id",
    "${local.ssm_prefix}/*/persistent/ahorro-cognito/client_id",
    "${local.ssm_prefix}/*/persistent/ahorro-cognito/issuer",
    "${local.ssm_prefix}/*/persistent/ahorro-cognito/region",
  ]
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = module.github_oidc_trust.json
}

# The app's CI, not the app itself: a workload identity is a separate role
# with its own trust. Grants grow here as the app's pipeline needs them.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "AllowReadRootDomainParameter"
    actions   = ["ssm:GetParameter"]
    resources = [local.root_domain_parameter_arn]
  }

  # Read only, and only these two prefixes. The pipeline deploys to namespaces
  # ahorro-dev and ahorro-pr; what stops it reaching namespace ahorro is the
  # cluster RBAC this token carries, not this policy.
  statement {
    sid       = "AllowReadAhorroDeployCredential"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [local.deploy_credential_parameter_arn]
  }

  # The user pool is shared by every environment: there is one pool and one
  # app client per project, because the API's verifier pins a single client id.
  statement {
    sid       = "AllowReadAhorroCognitoIdentifiers"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = local.cognito_parameter_arns
  }

  # The deploy token is a SecureString, so reading it needs the key as well as
  # the parameter. Without this the read fails as AccessDenied and the pipeline
  # cannot reach the cluster at all.
  #
  # alias/lab-secrets also encrypts other projects' passwords, including this
  # project's Cognito test user. SSM sets an EncryptionContext of the
  # parameter's own ARN, so the condition keeps Decrypt scoped to the one
  # parameter this role may read rather than to the whole shared key. StringLike,
  # not StringEquals, because the project segment is a wildcard here.
  statement {
    sid       = "AllowDecryptAhorroDeployToken"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.deploy_token_parameter_arn]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
