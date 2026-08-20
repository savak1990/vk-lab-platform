variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (argoproj.github.io/argo-helm)."
  type        = string
  default     = "10.4.0"
}

variable "repo_url" {
  description = "Git URL the root Application syncs from (aws target)."
  type        = string
}

variable "target_revision" {
  description = "Git ref the root Application syncs from."
  type        = string
  default     = "main"
}

variable "root_application_chart_path" {
  description = "Local path to the gitops/bootstrap chart (the root Application chart). Absolute, since this module runs from Terragrunt's cache dir, not the repo root."
  type        = string
}

