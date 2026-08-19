# The "state" lifecycle layer, one level below Bootstrap: the bucket every
# other unit stores its own Terraform state in. make state-up handles this
# unit's own first-run bootstrap, so this file never needs manual editing.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/terraform-state"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  bucket_name = "${local.project}-tf-state"
}
