# Shared config included by every unit under terraform/live/: AWS provider
# with default_tags for consistent resource identification, and the S3
# remote_state backend (native lockfile locking; no DynamoDB table needed).

locals {
  # Overridable via env vars so CI/integration runs can use a disposable
  # name/region instead of the personal lab's.
  project = get_env("PROJECT_NAME", "vk-lab-platform")

  # The account layer's units (kms, lab-role, github-oidc,
  # eks-access-identity - the "account"/"account-state" raw_class below) are
  # account-global and applied once, in one fixed region - ACCOUNT_MAIN_REGION,
  # independent of whatever PROJECT_REGION a given project uses for its own
  # cluster/state bucket. The shared KMS key in particular only exists in
  # this one region: secret-encrypt.sh/secret-decrypt.sh call it directly
  # under this same var, so a project run under a different PROJECT_REGION (e.g.
  # tests/manual/016's region-portability phase) still resolves the same key.
  account_main_region = get_env("ACCOUNT_MAIN_REGION", "eu-west-1")
  project_region      = get_env("PROJECT_REGION", "eu-west-1")

  # The account layer's own state (the shared lab-role/kms/github-oidc/
  # eks-access-identity units) must never live in any one project's own
  # bucket - a project's bootstrap-down deleting its own bucket would
  # otherwise orphan these account-global units' Terraform state too.
  # Derived from the repo owner, not PROJECT_NAME, so it's stable regardless
  # of which project happens to run account-up.
  github_repo_owner    = split("/", get_env("GITHUB_REPO", "savak1990/vk-lab-platform"))[0]
  account_state_bucket = "${local.github_repo_owner}-account-state"

  relative_path = path_relative_to_include()
  path_parts    = split("/", local.relative_path)

  # "ci/persistent/..." and "ci/disposable/..." map to the persistent/disposable
  # Lifecycle value they actually are (constitution §3), not "ci" itself.
  raw_class = local.path_parts[0] == "ci" ? local.path_parts[1] : local.path_parts[0]

  # "account" (the shared role/kms/oidc/access-identity units) and
  # "account-state" (that layer's own bucket, top-level so it's never
  # inside the tree account-down.sh's `terragrunt run --all destroy` walks)
  # both route to the account-global bucket, never a project's own.
  state_bucket = contains(["account", "account-state"], local.raw_class) ? local.account_state_bucket : "${local.project}-tf-state"

  # Same account-vs-project split as state_bucket above: the account
  # layer's units apply in ACCOUNT_MAIN_REGION regardless of PROJECT_REGION.
  aws_region = contains(["account", "account-state"], local.raw_class) ? local.account_main_region : local.project_region

  # Used by the eks unit for node group placement, pinning it to one fixed
  # AZ. Derived from PROJECT_REGION (not hardcoded) so switching PROJECT_REGION doesn't pin
  # the node group to a zone that doesn't exist in the new region - "a" is
  # present in every AWS region's standard zone-letter set. Name kept as
  # "postgres_az" despite having no Postgres-specific caller (ADR 0013 moved
  # Postgres off Terraform-owned storage) - not renamed for its one caller.
  postgres_az = "${local.project_region}a"

  # "account"/"account-state" are a scope, not a lifecycle class: their
  # resources are account-global rather than per-project, but they're still
  # Bootstrap-lifecycle (constitution §16 requires one of
  # bootstrap|persistent|disposable, not a scope name, on every tagged resource).
  lifecycle_class = lookup({ account = "bootstrap", "account-state" = "bootstrap" }, local.raw_class, local.raw_class)
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
