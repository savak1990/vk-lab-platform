variable "name" {
  description = "Name of the IAM role, e.g. \"ahorro-domain-reader\"."
  type        = string
}

variable "github_repo" {
  description = "owner/repo this role's OIDC trust is scoped to, e.g. \"savak1990/vk-ahorro\"."
  type        = string
}

variable "parameter_names" {
  description = "SSM parameter names the role may read, e.g. [\"/account/root_domain\"]. Plain String parameters only; a SecureString would also need kms:Decrypt."
  type        = list(string)
}
