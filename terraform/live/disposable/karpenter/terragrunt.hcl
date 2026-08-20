include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/karpenter-pod-identity"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name           = "mock-eks"
    node_subnet_id         = "subnet-00000000000000000"
    node_security_group_id = "sg-00000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  cluster_name           = dependency.eks.outputs.cluster_name
  node_subnet_id         = dependency.eks.outputs.node_subnet_id
  node_security_group_id = dependency.eks.outputs.node_security_group_id
}
