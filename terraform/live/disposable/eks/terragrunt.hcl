include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true # needed to read include.root.locals.postgres_az below
}

terraform {
  source = "${get_repo_root()}/terraform/modules/eks"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  cluster_name      = "${local.project}-eks"
  availability_zone = include.root.locals.postgres_az
}
