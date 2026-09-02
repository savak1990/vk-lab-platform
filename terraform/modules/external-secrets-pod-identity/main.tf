module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-external-secrets-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# alias/lab-secrets lives in ACCOUNT_MAIN_REGION, not this unit's own
# PROJECT_REGION - same reasoning as route53-zone's root_domain lookup.
data "aws_kms_alias" "secrets" {
  name   = "alias/lab-secrets"
  region = var.account_main_region
}

locals {
  postgres_password_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/postgres/app_password"
  grafana_password_arn  = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/grafana/admin_password"
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "AllowReadPlatformSecretParameters"
    actions   = ["ssm:GetParameter"]
    resources = [local.postgres_password_arn, local.grafana_password_arn]
  }

  # alias/lab-secrets also encrypts other projects' password parameters -
  # SSM sets an EncryptionContext of the parameter's own ARN, so this
  # condition keeps Decrypt scoped to just the two parameters this role can
  # read, not the whole shared key.
  statement {
    sid       = "AllowDecryptPlatformSecretParameters"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.postgres_password_arn, local.grafana_password_arn]
    }
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
