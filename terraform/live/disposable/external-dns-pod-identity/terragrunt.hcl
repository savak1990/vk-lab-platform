include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/external-dns-pod-identity"
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs = {
    cluster_name = "mock-eks"
  }
  # See aws-lb-controller-pod-identity's terragrunt.hcl for why "destroy" is
  # allowed here too - same reasoning applies verbatim.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

# Crosses into persistent/ like disposable/eks -> persistent/vpc already does.
# `make down`'s `run --all destroy` only discovers units under its own cwd
# (terraform/live/disposable), so this doesn't pull persistent/route53 into
# that scope.
dependency "route53" {
  config_path = "${get_repo_root()}/terraform/live/persistent/route53"

  mock_outputs = {
    zone_id = "Z00000000000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

inputs = {
  cluster_name   = dependency.eks.outputs.cluster_name
  hosted_zone_id = dependency.route53.outputs.zone_id
}
