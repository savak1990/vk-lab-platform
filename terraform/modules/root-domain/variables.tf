variable "root_domain_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the root domain value (secrets/root-domain.enc) - account-global, not filed under a project directory."
  type        = string
}
