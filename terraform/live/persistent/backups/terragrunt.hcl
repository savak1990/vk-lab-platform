include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read provider_region below.
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/postgres-backups"
}

inputs = {
  project         = get_env("PROJECT_NAME", "vk-lab-platform")
  provider_region = include.root.locals.provider_region
  ssm_layer       = "persistent"
}
