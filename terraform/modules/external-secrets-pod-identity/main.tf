module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-external-secrets-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# alias/lab-secrets - the same key that encrypts the committed .enc files
# also encrypts these two SecureString parameters (docs/adr/0023).
data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid     = "AllowReadPlatformSecretParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/postgres/app_password",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/grafana/admin_password",
    ]
  }

  statement {
    sid       = "AllowDecryptPlatformSecretParameters"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]
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
