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
  # Allows "destroy" too: destroy targets resources by their state-recorded
  # IDs, never recomputed from this mock - safe as long as this module has
  # no for_each/data lookup keyed on these values (it doesn't). Without this,
  # an eks unit left with no real outputs (a prior interrupted destroy)
  # bricks this unit's destroy even when it has nothing left to destroy.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  cluster_name           = dependency.eks.outputs.cluster_name
  node_subnet_id         = dependency.eks.outputs.node_subnet_id
  node_security_group_id = dependency.eks.outputs.node_security_group_id
}
