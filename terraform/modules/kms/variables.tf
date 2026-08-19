variable "name" {
  description = "Name used for the KMS key alias, e.g. \"vk-lab-platform-secrets\"."
  type        = string
}

variable "description" {
  description = "Human-readable description of what this key encrypts."
  type        = string
}

variable "deletion_window_in_days" {
  description = "Waiting period before the key is actually deleted after a destroy. 7 is AWS's minimum — KMS never deletes a key immediately, even when force_destroy-equivalent behavior is wanted, since an accidental key deletion is irreversible data loss."
  type        = number
  default     = 7
}
