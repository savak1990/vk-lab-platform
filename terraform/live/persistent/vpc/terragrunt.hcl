include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true # needed to read include.root.locals.postgres_az/aws_region below
}

terraform {
  source = "${get_repo_root()}/terraform/modules/vpc"
}

inputs = {
  availability_zones = [
    include.root.locals.postgres_az, # must be covered - see the eks unit's node group AZ pin
    "${include.root.locals.aws_region}b",
  ]
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}
