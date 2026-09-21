variable "project" {
  description = "PROJECT_NAME - names the SSH key and builds this project's SSM parameter path."
  type        = string
}

variable "public_key" {
  description = "The committed OpenSSH public key. The private half stays KMS-encrypted and never reaches Terraform."
  type        = string
}
