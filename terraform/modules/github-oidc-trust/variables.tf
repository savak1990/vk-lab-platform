variable "github_repo" {
  description = "owner/repo this trust statement's sub condition is scoped to, e.g. \"savak1990/vk-lab-platform\"."
  type        = string
}

variable "sub_suffix" {
  description = "The segment of the OIDC sub claim after 'repo:<repo>:' — '*' (any ref) by default, or 'environment:<name>' to pin the trust to one GitHub Environment."
  type        = string
  default     = "*"
}
