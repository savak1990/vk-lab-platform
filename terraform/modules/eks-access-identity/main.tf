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

data "aws_caller_identity" "current" {}

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

  # argo-up.sh/argo-down.sh chain a plain sts:AssumeRole onto this role from
  # whichever role GitHub Actions already assumed via OIDC (personal-lab-role
  # today). Trusting personal-lab-role's ARN directly as a principal would
  # force account-up to run again after bootstrap-up creates it - AWS
  # validates a named principal exists at policy-set time, and account-up
  # (this module) applies before bootstrap-up (personal-lab-role) ever does.
  # Trusting the account root instead, scoped down by a Condition, sidesteps
  # that: a condition value is a string match evaluated at AssumeRole time,
  # never checked for existence up front.
  statement {
    sid     = "ChainedAssumeFromRegisteredAutomationRoles"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/personal-lab-role"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}
