module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-external-secrets-controller"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

locals {
  postgres_password_arn         = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/postgres/app_password"
  grafana_password_arn          = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/grafana/admin_password"
  vast_ai_api_key_arn           = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/llm/vast_ai_api_key"
  llm_api_token_arn             = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/llm/api_token"
  llm_worker_seed_arn           = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/llm/worker_seed"
  llm_ssh_private_key_arn       = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/llm/ssh_private_key"
  llm_management_tokens_arn     = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/llm/management_tokens"
  chat_inference_key_arn        = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/inference_key"
  chat_db_password_arn          = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/db_password"
  chat_webui_secret_key_arn     = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/webui_secret_key"
  chat_admin_email_arn          = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/admin_email"
  chat_admin_password_arn       = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/admin_password"
  chat_google_client_id_arn     = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/google_client_id"
  chat_google_client_secret_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/chat/google_client_secret"
}

data "aws_iam_policy_document" "controller" {
  statement {
    sid       = "AllowReadPlatformSecretParameters"
    actions   = ["ssm:GetParameter"]
    resources = [local.postgres_password_arn, local.grafana_password_arn, local.vast_ai_api_key_arn, local.llm_api_token_arn, local.llm_worker_seed_arn, local.llm_ssh_private_key_arn, local.llm_management_tokens_arn, local.chat_inference_key_arn, local.chat_db_password_arn, local.chat_webui_secret_key_arn, local.chat_admin_email_arn, local.chat_admin_password_arn, local.chat_google_client_id_arn, local.chat_google_client_secret_arn]
  }

  # alias/lab-secrets also encrypts other projects' password parameters -
  # SSM sets an EncryptionContext of the parameter's own ARN, so this
  # condition keeps Decrypt scoped to just the parameters this role can
  # read, not the whole shared key.
  statement {
    sid       = "AllowDecryptPlatformSecretParameters"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.postgres_password_arn, local.grafana_password_arn, local.vast_ai_api_key_arn, local.llm_api_token_arn, local.llm_worker_seed_arn, local.llm_ssh_private_key_arn, local.llm_management_tokens_arn, local.chat_inference_key_arn, local.chat_db_password_arn, local.chat_webui_secret_key_arn, local.chat_admin_email_arn, local.chat_admin_password_arn, local.chat_google_client_id_arn, local.chat_google_client_secret_arn]
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
