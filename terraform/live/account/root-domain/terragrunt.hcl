include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/root-domain"
}

# account-global and shared: one root domain for every project in this
# account, not one per PROJECT_NAME - see docs/adr/0023.
locals {
  project             = get_env("PROJECT_NAME", "vk-lab-platform")
  account_main_region = get_env("ACCOUNT_MAIN_REGION", "eu-west-1")
}

inputs = {
  root_domain_secret_path = "${get_repo_root()}/secrets/${local.project}/root-domain.enc"
  main_account_region     = local.account_main_region
}
