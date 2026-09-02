include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/root-domain"
}

# account-global and shared: one root domain for every project in this
# account, not one per PROJECT_NAME.
locals {
  account_main_region = get_env("ACCOUNT_MAIN_REGION", "eu-west-1")
}

inputs = {
  root_domain_secret_path = "${get_repo_root()}/secrets/root-domain.enc"
  main_account_region     = local.account_main_region
}
