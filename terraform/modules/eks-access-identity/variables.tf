variable "name" {
  type    = string
  default = "eks-access-identity"
}

variable "github_repo" {
  description = "owner/repo this identity's OIDC trust is scoped to, e.g. \"viacheslav-klovan/vk-lab-platform\"."
  type        = string
}
