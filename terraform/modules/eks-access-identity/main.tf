# This role has no permission policy: get-token only performs sts:AssumeRole
# and signs a token locally. Cluster access comes from an EKS access-entry
# grant, not an IAM permission policy.
module "github_oidc_trust" {
  source      = "../github-oidc-trust"
  github_repo = var.github_repo
}

# `make account-up` always runs manually from a workstation, so whichever
# identity applies this *is* the operator. aws_iam_session_context resolves
# an SSO session's ARN to its underlying role ARN; a plain user ARN passes through.
data "aws_caller_identity" "operator" {}

data "aws_iam_session_context" "operator" {
  arn = data.aws_caller_identity.operator.arn
}

data "aws_iam_policy_document" "trust" {
  source_policy_documents = [module.github_oidc_trust.json]

  statement {
    sid     = "OperatorWorkstation"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_session_context.operator.issuer_arn]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}
