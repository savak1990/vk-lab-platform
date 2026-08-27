include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true # needed to read include.root.locals.postgres_az below
}

terraform {
  source = "${get_repo_root()}/terraform/modules/eks"
}

# Cross-lifecycle dependency (disposable -> persistent), same shape as
# disposable/external-secrets-pod-identity's dependency on persistent/secrets.
# Safe for `make down`: cluster-down.sh runs `terragrunt run --all destroy`
# scoped to terraform/live/disposable, and run --all only discovers units
# under the cwd - this dependency doesn't pull persistent/vpc into that scope.
dependency "vpc" {
  config_path = "${get_repo_root()}/terraform/live/persistent/vpc"

  mock_outputs = {
    vpc_id                  = "vpc-00000000000000000"
    public_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_subnet_ids_by_az = { "eu-west-1a" = "subnet-00000000000000001", "eu-west-1b" = "subnet-00000000000000002" }
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  cluster_name             = "${local.project}-eks"
  availability_zone        = include.root.locals.postgres_az
  vpc_id                   = dependency.vpc.outputs.vpc_id
  control_plane_subnet_ids = dependency.vpc.outputs.public_subnet_ids
  public_subnet_ids_by_az  = dependency.vpc.outputs.public_subnet_ids_by_az
}
