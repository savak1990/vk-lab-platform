module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-external-secrets-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "AllowReadPostgresAppSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.secret_arn]
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
