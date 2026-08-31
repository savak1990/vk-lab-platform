data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "this" {
  statement {
    sid     = "GithubActionsOidc"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scopes which repo can assume the role using this statement - not which
    # PROJECT_NAME a run targets. That's enforced by the caller's own resource
    # ARNs, not this sub claim.
    #
    # Two patterns, not one: GitHub's actual issued sub claim (confirmed via
    # CloudTrail after a real AssumeRoleWithWebIdentity denial) embeds
    # immutable owner/repo IDs - "repo:savak1990@4834932/vk-lab-platform@1339701176:ref:...",
    # not the plain "repo:savak1990/vk-lab-platform:...". The plain pattern is
    # kept too in case a differently-configured repo/account still issues it.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:*",
        "repo:${replace(var.github_repo, "/", "@*/")}@*:*",
      ]
    }
  }
}
