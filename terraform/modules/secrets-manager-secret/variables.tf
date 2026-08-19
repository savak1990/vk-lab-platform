variable "name" {
  description = "Name of the Secrets Manager secret."
  type        = string
}

variable "secrets" {
  description = "Map of JSON key name => absolute path to that value's KMS-encrypted ciphertext file. Every entry is decrypted and stored together as one JSON-encoded secret."
  type        = map(string)
}
