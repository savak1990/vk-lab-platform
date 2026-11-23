include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read provider_region below.
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/hcloud-network"
}

inputs = {
  project      = get_env("PROJECT_NAME", "vk-lab-platform")
  network_zone = include.root.locals.provider_region
}
