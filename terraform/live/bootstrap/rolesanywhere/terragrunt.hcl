include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read provider_region below.
  expose = true
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
  project     = get_env("PROJECT_NAME", "vk-lab-platform")
  secrets_dir = "${get_repo_root()}/secrets/${local.project}"

  # Read from disk rather than from PROVIDER, so the chain is always named
  # after the certificate that is actually loaded. A separate environment
  # variable could disagree with the file: renaming the live trust anchor,
  # or pointing at a missing file and planning the whole chain away.
  ca_provider = fileexists("${local.secrets_dir}/civo-ca-cert.pem") ? "civo" : (
    fileexists("${local.secrets_dir}/hetzner-ca-cert.pem") ? "hetzner" : "aws"
  )
  ca_cert_path = "${local.secrets_dir}/${local.ca_provider}-ca-cert.pem"
}

inputs = {
  project         = local.project
  provider_region = include.root.locals.provider_region
  provider_name   = local.ca_provider
  ca_cert_pem     = fileexists(local.ca_cert_path) ? file(local.ca_cert_path) : ""
  hosted_zone_id  = dependency.route53.outputs.zone_id
}
