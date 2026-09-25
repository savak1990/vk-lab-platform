include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/ahorro-cognito"
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  project = local.project
  # Non-deliverable by design: the user is created with SUPPRESS and a
  # permanent password, so nothing is ever sent to this address.
  test_user_email                = "e2e@vk-ahorro.invalid"
  test_user_password_secret_path = "${get_repo_root()}/secrets/${local.project}/ahorro-test-user-password.enc"
}
