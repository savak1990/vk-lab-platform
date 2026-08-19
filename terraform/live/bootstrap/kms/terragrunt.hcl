include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/kms"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  name        = "${local.project}-secrets"
  description = "Encrypts/decrypts per-file bootstrap config and secrets committed under secrets/*.enc."
}
