include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/persistent-secrets"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  project                            = local.project
  postgres_app_password_secret_path  = "${get_repo_root()}/secrets/${local.project}/postgres-app-password.enc"
  grafana_admin_password_secret_path = "${get_repo_root()}/secrets/${local.project}/grafana-admin-password.enc"
  argocd_admin_password_bcrypt_path  = "${get_repo_root()}/secrets/${local.project}/argocd-admin-password.bcrypt"
}
