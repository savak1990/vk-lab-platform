include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/hcloud-ssh-key"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")

  # Read here rather than inside the module: a relative path there would
  # resolve against the cached copy of the module, not the repository.
  key_path = "${get_repo_root()}/secrets/${local.project}/hetzner-ssh-key.pub"
}

inputs = {
  project = local.project
  # Absent for a project that has never run ssh-key-init, and validate must
  # still succeed there.
  public_key = fileexists(local.key_path) ? file(local.key_path) : ""
}
