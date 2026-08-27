data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# No AWS-managed policy exists for ExternalDNS - scoped to the single hosted
# zone it's allowed to touch. ListHostedZones has no resource-level permission
# support in AWS IAM, so it stays "*" - not a scoping gap this module can close.
data "aws_iam_policy_document" "controller" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }

  statement {
    actions   = ["route53:ListHostedZones", "route53:GetChange"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "controller" {
  name   = "controller"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller.json
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.service_account_namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.controller.arn
}
