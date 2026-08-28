module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-external-dns"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
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
  role   = module.pod_identity.role_name
  policy = data.aws_iam_policy_document.controller.json
}

moved {
  from = aws_iam_role.controller
  to   = module.pod_identity.aws_iam_role.controller
}

moved {
  from = aws_eks_pod_identity_association.controller
  to   = module.pod_identity.aws_eks_pod_identity_association.controller
}
