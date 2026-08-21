variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (argoproj.github.io/argo-helm)."
  type        = string
  default     = "10.4.0"
}

variable "repo_url" {
  description = "Git URL the root Application syncs from (aws target)."
  type        = string
}

variable "project" {
  description = "Project name (PROJECT_NAME), threaded to the umbrella chart so AWS-resource-name-derived manifests (e.g. Karpenter's cluster name) match a non-default project."
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

variable "admin_password_bcrypt_hash_path" {
  description = "Local path to the committed bcrypt hash of the Argo CD admin password (secrets/<project>/argocd-admin-password.bcrypt)."
  type        = string
}

variable "postgres_existing_volume_handle" {
  description = "The Terraform-owned Postgres EBS volume's ID (persistent/postgres-volume's output), threaded through to gitops/values.yaml's postgres.existingVolumeHandle so CNPG binds to it automatically."
  type        = string
}

variable "postgres_existing_volume_az" {
  description = "The Terraform-owned Postgres EBS volume's AZ (persistent/postgres-volume's output), threaded through to gitops/values.yaml's postgres.existingVolumeAz."
  type        = string
}

variable "postgres_existing_volume_size" {
  description = "The Terraform-owned Postgres EBS volume's size, e.g. \"10Gi\" (persistent/postgres-volume's output), threaded through to gitops/values.yaml's postgres.existingVolumeSize."
  type        = string
}

