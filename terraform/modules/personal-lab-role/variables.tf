variable "name" {
  type    = string
  default = "personal-lab-role"
}

variable "github_repo" {
  description = "owner/repo this role's OIDC trust is scoped to, e.g. \"savak1990/vk-lab-platform\"."
  type        = string
}

variable "project" {
  description = "PROJECT_NAME of the one registered combination this role's permissions are scoped to (the state bucket name, cluster name prefix, etc. are all derived from this)."
  type        = string
}

variable "cluster_name" {
  description = "Must match disposable/eks's cluster_name input for this project (\"<project>-eks\")."
  type        = string
}
