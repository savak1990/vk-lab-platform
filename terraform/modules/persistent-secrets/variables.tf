variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter paths."
  type        = string
}

variable "postgres_app_password_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Postgres app-user password."
  type        = string
}

variable "grafana_admin_password_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Grafana admin password."
  type        = string
}

variable "vast_ai_api_key_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the vast.ai API key, global scope - one key shared by every project in the account."
  type        = string
}

variable "llm_api_token_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the static bearer token for vk-llm-on-demand's own API, global scope - one token shared by every project in the account."
  type        = string
}

variable "argocd_admin_password_bcrypt_path" {
  description = "Absolute path to the committed, plaintext bcrypt hash of the Argo CD admin password (never KMS-encrypted - it's a one-way hash, not a reversible credential)."
  type        = string
}
