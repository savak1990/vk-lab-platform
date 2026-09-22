include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/hcloud-nodes"
}

dependency "persistent_network" {
  config_path = "${get_repo_root()}/terraform/live/persistent-hetzner/network"

  mock_outputs = {
    network_id      = "00000000"
    subnet_ip_range = "10.0.1.0/24"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "ssh_key" {
  config_path = "${get_repo_root()}/terraform/live/persistent-hetzner/ssh-key"

  mock_outputs = {
    ssh_key_id = "00000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "firewall" {
  config_path = "${get_repo_root()}/terraform/live/cluster-hetzner/firewall"

  mock_outputs = {
    firewall_id = "00000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  project         = get_env("PROJECT_NAME", "vk-lab-platform")
  node_count      = tonumber(get_env("NODE_COUNT", "3"))
  node_type       = get_env("NODE_TYPE", "cx33")
  location        = get_env("REGION", "fsn1")
  network_id      = dependency.persistent_network.outputs.network_id
  subnet_ip_range = dependency.persistent_network.outputs.subnet_ip_range
  ssh_key_id      = dependency.ssh_key.outputs.ssh_key_id
  firewall_id     = dependency.firewall.outputs.firewall_id
}
