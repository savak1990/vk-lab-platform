include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/route53-zone"
}

locals {
  project   = get_env("PROJECT_NAME", "vk-lab-platform")
  subdomain = get_env("SUBDOMAIN", "lab")
}

inputs = {
  root_domain_secret_path = "${get_repo_root()}/secrets/${local.project}/root-domain.enc"
  subdomain               = local.subdomain
}
