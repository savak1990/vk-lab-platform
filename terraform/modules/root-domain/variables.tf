variable "root_domain_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the root domain value (secrets/<project>/root-domain.enc). Applied once, account-globally, even though the file lives under a project-named directory - no account-level secrets convention exists yet."
  type        = string
}

variable "main_account_region" {
  description = "The account lifecycle's own fixed region (ACCOUNT_MAIN_REGION), recorded so scripts can discover it without an env var."
  type        = string
}
