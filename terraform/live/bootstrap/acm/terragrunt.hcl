include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/acm-certificate"
}

dependency "route53" {
  config_path = "../route53"

  mock_outputs = {
    zone_id = "MOCK"
    fqdn    = "lab.example.invalid"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  fqdn    = dependency.route53.outputs.fqdn
  zone_id = dependency.route53.outputs.zone_id
}
