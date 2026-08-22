# Shared config included by every unit under terraform/live/: AWS provider
# with default_tags for consistent resource identification, and the S3
# remote_state backend (native lockfile locking; no DynamoDB table needed).

locals {
  # Overridable via env vars so CI/integration runs can use a disposable
  # name/region instead of the personal lab's.
  aws_region   = get_env("REGION", "eu-west-1")
  project      = get_env("PROJECT_NAME", "vk-lab-platform")
  state_bucket = "${local.project}-tf-state"

  # Used by the eks unit for node group placement. Was also shared with a
  # Terraform-owned Postgres EBS volume (persistent/postgres-volume); that
  # unit is gone (Postgres storage moved to CNPG VolumeSnapshot recovery,
  # see ADR 0013) but the name is kept as-is rather than renamed for a
  # single remaining caller.
  postgres_az = "eu-west-1a"

  relative_path = path_relative_to_include()
  path_parts    = split("/", local.relative_path)

  # "ci/persistent/..." and "ci/disposable/..." map to the persistent/disposable
  # Lifecycle value they actually are (constitution §3), not "ci" itself.
  lifecycle_class = local.path_parts[0] == "ci" ? local.path_parts[1] : local.path_parts[0]
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project   = "${local.project}"
      Scope     = "platform"
      Lifecycle = "${local.lifecycle_class}"
      ManagedBy = "terraform"
    }
  }
}
EOF
}

# A unit can define its own remote_state block to replace this one (used
# only by scripts/state-up.sh's temporary local-backend bootstrap step).
remote_state {
  backend = "s3"
  config = {
    bucket       = local.state_bucket
    key          = "${local.relative_path}/terraform.tfstate"
    region       = local.aws_region
    use_lockfile = true
    encrypt      = true
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
