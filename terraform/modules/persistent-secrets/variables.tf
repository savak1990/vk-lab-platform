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

variable "llm_worker_seed_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding vk-llm-on-demand's 32-byte worker seed, global scope."
  type        = string
}

variable "llm_ssh_private_key_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding vk-llm-on-demand's ed25519 private key, global scope."
  type        = string
}

variable "llm_management_tokens_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding vk-llm-on-demand's management tokens, global scope."
  type        = string
}

variable "chat_inference_key_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding Open WebUI's sk-vkllm- inference key, global scope."
  type        = string
}

variable "chat_db_password_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the openwebui Postgres role password, global scope."
  type        = string
}

variable "chat_webui_secret_key_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding Open WebUI's session signing key, global scope."
  type        = string
}

variable "chat_admin_email_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Open WebUI admin email, global scope."
  type        = string
}

variable "chat_admin_password_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Open WebUI first-start admin password, global scope."
  type        = string
}

variable "chat_google_client_id_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Google OAuth client ID for Open WebUI, global scope."
  type        = string
}

variable "chat_google_client_secret_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the Google OAuth client secret for Open WebUI, global scope."
  type        = string
}
