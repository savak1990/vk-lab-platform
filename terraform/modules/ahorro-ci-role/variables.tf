variable "name" {
  type    = string
  default = "ahorro-ci-role"
}

variable "github_repo" {
  description = "owner/repo this role's OIDC trust is scoped to, e.g. \"savak1990/vk-ahorro\"."
  type        = string
}
