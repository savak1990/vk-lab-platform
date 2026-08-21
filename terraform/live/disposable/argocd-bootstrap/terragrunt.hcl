include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/argocd-bootstrap"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name                       = "mock-eks"
    cluster_endpoint                   = "https://mock.invalid"
    cluster_certificate_authority_data = "bW9jaw=="
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Safe despite crossing lifecycles: the Makefile always runs `persistent-up`
# before `disposable-up`, so this unit's outputs already exist when read.
dependency "postgres_volume" {
  config_path = "../../persistent/postgres-volume"

  mock_outputs = {
    volume_id         = "vol-00000000000000000"
    availability_zone = "eu-west-1a"
    size_gb           = 10
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Unit-local provider: only this unit talks to the Kubernetes API, so the
# helm provider lives here rather than in the shared root.hcl.
generate "k8s_providers" {
  path      = "k8s_providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "helm" {
  kubernetes = {
    host                   = "${dependency.eks.outputs.cluster_endpoint}"
    cluster_ca_certificate = base64decode("${dependency.eks.outputs.cluster_certificate_authority_data}")

    exec = {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", "${dependency.eks.outputs.cluster_name}"]
    }
  }
}
EOF
}

inputs = {
  project                         = local.project
  repo_url                        = "https://github.com/savak1990/vk-lab-platform"
  root_application_chart_path     = "${get_repo_root()}/gitops/bootstrap"
  admin_password_bcrypt_hash_path = "${get_repo_root()}/secrets/${local.project}/argocd-admin-password.bcrypt"
  postgres_existing_volume_handle = dependency.postgres_volume.outputs.volume_id
  postgres_existing_volume_az     = dependency.postgres_volume.outputs.availability_zone
  postgres_existing_volume_size   = "${dependency.postgres_volume.outputs.size_gb}Gi"
}
