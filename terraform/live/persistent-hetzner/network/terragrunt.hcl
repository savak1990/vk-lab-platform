include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/hcloud-network"
}

inputs = {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}
