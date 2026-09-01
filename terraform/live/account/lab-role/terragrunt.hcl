include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules//lab-role"
}

# account-global and shared: no PROJECT_NAME input. Applied once, reused by
# every project's GitHub Actions runs.
locals {
  github_repo = get_env("GITHUB_REPO", "savak1990/vk-lab-platform")
}

inputs = {
  github_repo = local.github_repo
}
