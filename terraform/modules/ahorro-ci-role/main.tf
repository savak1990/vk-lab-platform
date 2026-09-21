module "github_oidc_trust" {
  source      = "../github-oidc-trust"
  github_repo = var.github_repo
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  root_domain_parameter_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/account/root_domain"
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
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-permissions"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
