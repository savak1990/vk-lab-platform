# The Account layer's own dedicated state bucket - never a project's own
# ${PROJECT_NAME}-tf-state (root.hcl's account_state_bucket local routes
# "account-state" to it automatically). Kept as its own top-level directory,
# a sibling of account/ rather than nested inside it, for the same reason
# terraform/live/state/ sits outside bootstrap/: `terragrunt run --all
# destroy` in account/ (account-down.sh) must never discover this unit and
# try to destroy the very bucket its own Terraform state lives in.
# scripts/account-state-up.sh handles this unit's own first-run bootstrap,
# so this file never needs manual editing.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/terraform-state"
}

locals {
  github_repo_owner = split("/", get_env("GITHUB_REPO", "savak1990/vk-lab-platform"))[0]
}

inputs = {
  bucket_name = "${local.github_repo_owner}-account-state"
}
