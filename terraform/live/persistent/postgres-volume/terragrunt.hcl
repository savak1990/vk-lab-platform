include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true # needed to read include.root.locals.postgres_az below
}

terraform {
  source = "${get_repo_root()}/terraform/modules/ebs-volume"
}

inputs = {
  # Only read at creation time (see the module's ignore_changes note) —
  # Postgres storage is grown exclusively through the CNPG Cluster CR's
  # spec.storage.size, never by editing this value.
  size_gb           = 10
  availability_zone = include.root.locals.postgres_az
  component         = "postgres"
}
