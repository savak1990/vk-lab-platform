# Shared config included by every unit under terraform/live/: AWS provider
# with default_tags for consistent resource identification, and the S3
# remote_state backend (native lockfile locking; no DynamoDB table needed).

locals {
  # Overridable via env vars so CI/integration runs can use a disposable
  # name/region instead of the personal lab's.
  aws_region   = get_env("REGION", "eu-west-1")
  project      = get_env("PROJECT_NAME", "vk-lab-platform")
  state_bucket = "${local.project}-tf-state"

  # Used by the eks unit for node group placement, pinning it to one fixed
  # AZ. Derived from REGION (not hardcoded) so switching REGION doesn't pin
  # the node group to a zone that doesn't exist in the new region - "a" is
  # present in every AWS region's standard zone-letter set. Name kept as
  # "postgres_az" despite having no Postgres-specific caller (ADR 0013 moved
  # Postgres off Terraform-owned storage) - not renamed for its one caller.
  postgres_az = "${local.aws_region}a"

  relative_path = path_relative_to_include()
  path_parts    = split("/", local.relative_path)

  # "ci/persistent/..." and "ci/disposable/..." map to the persistent/disposable
  # Lifecycle value they actually are (constitution §3), not "ci" itself.
  raw_class = local.path_parts[0] == "ci" ? local.path_parts[1] : local.path_parts[0]

  # "account" is a scope, not a lifecycle class: its resources are account-global
  # rather than per-project, but they're still Bootstrap-lifecycle.
  lifecycle_class = lookup({ account = "bootstrap" }, local.raw_class, local.raw_class)
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
