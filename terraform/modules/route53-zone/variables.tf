variable "root_domain_secret_path" {
  description = "Absolute path to the KMS-encrypted ciphertext file holding the root domain value (secrets/<project>/root-domain.enc)."
  type        = string
}

variable "subdomain" {
  description = "Subdomain delegated from the root domain for this platform, e.g. \"lab\" in lab.<root-domain>."
  type        = string
  default     = "lab"
}
