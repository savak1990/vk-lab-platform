include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/kms"
}

# account-global and shared: one key for every project's secrets, not one
# per PROJECT_NAME.
inputs = {
  name        = "lab-secrets"
  description = "Encrypts/decrypts per-file secrets committed under secrets/**/*.enc, shared by every project in this account."
}
