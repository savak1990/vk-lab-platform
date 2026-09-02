variable "root_domain_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the root domain value (secrets/root-domain.enc) - account-global, not filed under a project directory."
  type        = string
}

variable "main_account_region" {
  description = "The account lifecycle's own fixed region (ACCOUNT_MAIN_REGION), recorded so scripts can discover it without an env var."
  type        = string
}
