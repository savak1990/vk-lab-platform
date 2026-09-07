include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/civo-network"
}

dependency "persistent_network" {
  config_path = "${get_repo_root()}/terraform/live/persistent-civo/network"

  mock_outputs = {
    network_id = "00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  project          = local.project
  create_network   = false
  create_firewalls = true
  network_id       = dependency.persistent_network.outputs.network_id
}
