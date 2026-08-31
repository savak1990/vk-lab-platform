include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules//personal-lab-role"
}

locals {
  project     = get_env("PROJECT_NAME", "vk-lab-platform")
  github_repo = get_env("GITHUB_REPO", "savak1990/vk-lab-platform")
}

inputs = {
  project      = local.project
  cluster_name = "${local.project}-eks"
  github_repo  = local.github_repo
}
