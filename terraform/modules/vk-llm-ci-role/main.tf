module "github_oidc_trust" {
  source      = "../github-oidc-trust"
  github_repo = var.github_repo
  # Pinned to the gpu-control Environment's OIDC sub claim, not a wildcard
  # branch: this role can decrypt a bearer credential, so only runs inside
  # that Environment may assume it.
  sub_suffix = "environment:gpu-control"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# kms:Decrypt in an identity policy is checked against the underlying key's
# ARN, not an alias ARN - an alias-ARN resource element would silently grant
# nothing.
data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

locals {
  ssm_prefix = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter"

  # Wildcarded on the project, not on the path: same reasoning as
  # ahorro-ci-role - one role serves every lab project, and the project a
  # run targets is its own input, not this role's concern.
  api_token_parameter_arn = "${local.ssm_prefix}/*/persistent/llm/api_token"
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = module.github_oidc_trust.json
}

# gpu-control.yml's only AWS call: read the one management-API bearer token
# vk-llm-on-demand's GitHub Actions remote control needs. Nothing else.
data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "AllowReadLlmApiToken"
    actions   = ["ssm:GetParameter"]
    resources = [local.api_token_parameter_arn]
  }

  # The parameter is a SecureString, so reading it needs the key as well as
  # the parameter. The EncryptionContext condition keeps Decrypt scoped to
  # this one parameter pattern, not the whole shared key.
  statement {
    sid       = "AllowDecryptLlmApiToken"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.api_token_parameter_arn]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
