include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules//eks-access-identity"
}

locals {
  github_repo = get_env("GITHUB_REPO", "savak1990/vk-lab-platform")
}

inputs = {
  name        = "eks-test-identity"
  github_repo = local.github_repo
}
