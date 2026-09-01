variable "name" {
  type    = string
  default = "lab-role"
}

variable "github_repo" {
  description = "owner/repo this role's OIDC trust is scoped to, e.g. \"savak1990/vk-lab-platform\"."
  type        = string
}
