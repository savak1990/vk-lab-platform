include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules//ssm-reader-role"
}

# account-global and shared: the role is scoped to the consuming repository,
# not to a PROJECT_NAME.
locals {
  github_repo = get_env("AHORRO_GITHUB_REPO", "savak1990/vk-ahorro")
}

inputs = {
  name            = "ahorro-domain-reader"
  github_repo     = local.github_repo
  parameter_names = ["/account/root_domain"]
}
