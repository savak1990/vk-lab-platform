include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/rolesanywhere"
}

dependency "route53" {
  config_path = "../route53"

  mock_outputs = {
    zone_id = "MOCK"
    fqdn    = "lab.example.invalid"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

locals {
  # Same default as every sibling unit (root.hcl, acm, route53) - fails
  # closed to the AWS project's state/tags if PROJECT_NAME is ever unset,
  # rather than silently targeting the Civo project's real resources.
  project      = get_env("PROJECT_NAME", "vk-lab-platform")
  ca_cert_path = "${get_repo_root()}/secrets/${local.project}/civo-ca-cert.pem"
}

inputs = {
  project        = local.project
  ca_cert_pem    = fileexists(local.ca_cert_path) ? file(local.ca_cert_path) : ""
  hosted_zone_id = dependency.route53.outputs.zone_id
}
