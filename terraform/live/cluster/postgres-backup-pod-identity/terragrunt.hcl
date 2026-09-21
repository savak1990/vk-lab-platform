include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read provider_region below.
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules//postgres-backup-pod-identity"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name = "mock-eks"
  }
  # Same rationale as ebs-csi-pod-identity/karpenter's dependency block:
  # allows destroy even when eks has no real outputs left (a prior
  # interrupted destroy), since nothing here is keyed on cluster_name via
  # for_each/data lookups.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  cluster_name    = dependency.eks.outputs.cluster_name
  project         = get_env("PROJECT_NAME", "vk-lab-platform")
  provider_region = include.root.locals.provider_region
}
