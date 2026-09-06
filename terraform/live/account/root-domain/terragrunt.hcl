include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/root-domain"
}

# account-global and shared: one root domain for every project in this
# account, not one per PROJECT_NAME.
inputs = {
  root_domain_secret_path = "${get_repo_root()}/secrets/root-domain.enc"
}
