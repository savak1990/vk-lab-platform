include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/secrets-manager-secret"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  name = "${local.project}-secrets"
  secrets = {
    postgres_app_password  = "${get_repo_root()}/secrets/${local.project}/postgres-app-password.enc"
    root_domain            = "${get_repo_root()}/secrets/${local.project}/root-domain.enc"
    grafana_admin_password = "${get_repo_root()}/secrets/${local.project}/grafana-admin-password.enc"
  }
}
