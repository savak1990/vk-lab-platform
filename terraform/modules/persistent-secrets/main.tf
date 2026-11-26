data "aws_kms_secrets" "this" {
  secret {
    name    = "postgres_app_password"
    payload = filebase64(var.postgres_app_password_secret_path)
  }
  secret {
    name    = "grafana_admin_password"
    payload = filebase64(var.grafana_admin_password_secret_path)
  }
  secret {
    name    = "vast_ai_api_key"
    payload = filebase64(var.vast_ai_api_key_secret_path)
  }
  secret {
    name    = "llm_api_token"
    payload = filebase64(var.llm_api_token_secret_path)
  }
  secret {
    name    = "llm_worker_seed"
    payload = filebase64(var.llm_worker_seed_secret_path)
  }
  secret {
    name    = "llm_ssh_private_key"
    payload = filebase64(var.llm_ssh_private_key_secret_path)
  }
  secret {
    name    = "llm_management_tokens"
    payload = filebase64(var.llm_management_tokens_secret_path)
  }
  secret {
    name    = "chat_inference_key"
    payload = filebase64(var.chat_inference_key_secret_path)
  }
  secret {
    name    = "chat_db_password"
    payload = filebase64(var.chat_db_password_secret_path)
  }
  secret {
    name    = "chat_webui_secret_key"
    payload = filebase64(var.chat_webui_secret_key_secret_path)
  }
  secret {
    name    = "chat_admin_email"
    payload = filebase64(var.chat_admin_email_secret_path)
  }
  secret {
    name    = "chat_admin_password"
    payload = filebase64(var.chat_admin_password_secret_path)
  }
  secret {
    name    = "chat_google_client_id"
    payload = filebase64(var.chat_google_client_id_secret_path)
  }
  secret {
    name    = "chat_google_client_secret"
    payload = filebase64(var.chat_google_client_secret_secret_path)
  }
}

resource "aws_ssm_parameter" "postgres_app_password" {
  name        = "/${var.project}/persistent/postgres/app_password"
  value       = data.aws_kms_secrets.this.plaintext["postgres_app_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Postgres app-user (vkdb) password. Never regenerated once set (ADR 0014) - must stay byte-identical across a CNPG snapshot recovery."
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name        = "/${var.project}/persistent/grafana/admin_password"
  value       = data.aws_kms_secrets.this.plaintext["grafana_admin_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Grafana admin password."
}

resource "aws_ssm_parameter" "vast_ai_api_key" {
  name        = "/${var.project}/persistent/llm/vast_ai_api_key"
  value       = data.aws_kms_secrets.this.plaintext["vast_ai_api_key"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "vast.ai API key (instance read/write scope) used by vk-llm-on-demand."
}

resource "aws_ssm_parameter" "llm_api_token" {
  name        = "/${var.project}/persistent/llm/api_token"
  value       = data.aws_kms_secrets.this.plaintext["llm_api_token"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Inference client keys (sk-vkllm-…, one per line) callers present to vk-llm-on-demand's /v1 routes."
}

resource "aws_ssm_parameter" "llm_worker_seed" {
  name        = "/${var.project}/persistent/llm/worker_seed"
  value       = data.aws_kms_secrets.this.plaintext["llm_worker_seed"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "32-byte seed vk-llm-on-demand derives per-instance worker keys from. Byte-exact: no trailing newline."
}

resource "aws_ssm_parameter" "llm_ssh_private_key" {
  name        = "/${var.project}/persistent/llm/ssh_private_key"
  value       = data.aws_kms_secrets.this.plaintext["llm_ssh_private_key"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "ed25519 private key vk-llm-on-demand uses to tunnel into rented vast.ai instances; the public half is registered on the vast.ai account."
}

resource "aws_ssm_parameter" "llm_management_tokens" {
  name        = "/${var.project}/persistent/llm/management_tokens"
  value       = data.aws_kms_secrets.this.plaintext["llm_management_tokens"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Management tokens (one per line) for vk-llm-on-demand's /api/v1/gpu routes: the CLI and the GitHub Actions workflow. Never the same value as api_token."
}

resource "aws_ssm_parameter" "chat_inference_key" {
  name        = "/${var.project}/persistent/chat/inference_key"
  value       = data.aws_kms_secrets.this.plaintext["chat_inference_key"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Open WebUI's own sk-vkllm- inference key; the gateway's client-keys also lists it."
}

resource "aws_ssm_parameter" "chat_db_password" {
  name        = "/${var.project}/persistent/chat/db_password"
  value       = data.aws_kms_secrets.this.plaintext["chat_db_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Password of the openwebui role in lab-postgres. Hex only, so it is safe inside a DATABASE_URL."
}

resource "aws_ssm_parameter" "chat_webui_secret_key" {
  name        = "/${var.project}/persistent/chat/webui_secret_key"
  value       = data.aws_kms_secrets.this.plaintext["chat_webui_secret_key"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Open WebUI WEBUI_SECRET_KEY (session signing)."
}

resource "aws_ssm_parameter" "chat_admin_email" {
  name        = "/${var.project}/persistent/chat/admin_email"
  value       = data.aws_kms_secrets.this.plaintext["chat_admin_email"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Open WebUI admin email, read only when the database has no users."
}

resource "aws_ssm_parameter" "chat_admin_password" {
  name        = "/${var.project}/persistent/chat/admin_password"
  value       = data.aws_kms_secrets.this.plaintext["chat_admin_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Open WebUI first-start admin password; later changes happen in the admin panel."
}

resource "aws_ssm_parameter" "chat_google_client_id" {
  name        = "/${var.project}/persistent/chat/google_client_id"
  value       = data.aws_kms_secrets.this.plaintext["chat_google_client_id"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Google OAuth client ID for Open WebUI's \"Continue with Google\"."
}

resource "aws_ssm_parameter" "chat_google_client_secret" {
  name        = "/${var.project}/persistent/chat/google_client_secret"
  value       = data.aws_kms_secrets.this.plaintext["chat_google_client_secret"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Google OAuth client secret for Open WebUI's \"Continue with Google\"."
}

# A one-way bcrypt hash, never encrypted before or after this - it isn't a
# reversible credential, so a plain String parameter (not SecureString) is
# the right fit, same reasoning as fqdn/root_domain elsewhere in this plan.
resource "aws_ssm_parameter" "argocd_admin_password_bcrypt" {
  name        = "/${var.project}/persistent/argocd/admin_password_bcrypt"
  value       = trimspace(file(var.argocd_admin_password_bcrypt_path))
  type        = "String"
  description = "Bcrypt hash of the Argo CD admin password, injected by scripts/argo-up.sh before Argo CD (and External Secrets Operator) exist - ADR 0012."
}
