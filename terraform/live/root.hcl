# Shared config included by every unit under terraform/live/: AWS provider
# with default_tags for consistent resource identification, and the S3
# remote_state backend (native lockfile locking; no DynamoDB table needed).

locals {
  # Overridable via env var so CI/integration runs can use a disposable
  # name instead of the personal lab's.
  project = get_env("PROJECT_NAME", "vk-lab-platform")

  # The account layer never moves: its KMS key, lab-role, OIDC provider and
  # own state bucket all live here, and deriving this is what ADR 0024
  # prohibits - unchanged for this layer.
  account_region = "eu-west-1"

  provider_name = get_env("PROVIDER", "aws")
  region_input  = get_env("REGION", "")

  # Every AWS resource this platform creates lives in the account region,
  # whatever the target. REGION selects a Civo region or a Hetzner location
  # and never an AWS one, so no layer varies this.
  aws_region = local.account_region

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
  state_bucket = contains(["account", "account-state"], local.raw_class) ? local.account_state_bucket : "${local.project}-${local.provider_region}-tf-state"

  # The provider's own region, lowercased: what namespaces this project's
  # state. The bucket is an AWS resource living in aws_region, but its name
  # says whose state it holds - two Civo regions sharing one state would let
  # the second orphan the first's network.
  provider_region = lower(
    local.provider_name == "civo" ? local.civo_region : (
    local.provider_name == "hetzner" ? local.hcloud_location : local.aws_region)
  )

  # Used by the eks unit for node group placement, pinning it to one fixed
  # AZ. Retained EBS volumes are AZ-bound, so this pin is what lets them
  # rebind across make down/make up. Name kept as "postgres_az" despite
  # having no Postgres-specific caller - not renamed for its one caller.
  postgres_az = "${local.aws_region}a"

  # "account"/"account-state" are a scope, not a lifecycle class: their
  # resources are account-global rather than per-project, but they're still
  # Bootstrap-lifecycle (constitution §16 requires one of
  # bootstrap|persistent|disposable, not a scope name, on every tagged resource).
  # "cluster" is likewise a directory name, not a lifecycle class - the
  # constitution's tag vocabulary is disposable, so it maps back to that.
  lifecycle_class = lookup({ account = "bootstrap", "account-state" = "bootstrap", cluster = "disposable", "cluster-civo" = "disposable", "cluster-hetzner" = "disposable", "persistent-civo" = "persistent", "persistent-hetzner" = "persistent" }, local.raw_class, local.raw_class)

  civo_region = local.provider_name == "civo" && local.region_input != "" ? local.region_input : "LON1"

  # Civo stacks get a civo provider in addition to aws - their units still
  # write SSM parameters, so both providers are needed in the same unit. The
  # token is read from CIVO_TOKEN by the provider itself and is deliberately
  # never written here, so it cannot reach the generated file or the state.
  civo_stack = contains(["persistent-civo", "cluster-civo"], local.raw_class)

  # Interpolated directly after the aws block's closing brace, so an aws stack
  # renders the empty string and its provider.tf stays byte-identical.
  civo_provider = local.civo_stack ? "\nprovider \"civo\" {\n  region = \"${local.civo_region}\"\n}" : ""

  # Also declared in scripts/lib/region.sh - Terraform and shell each need
  # their own copy, since neither can read the other's.
  hcloud_location = local.provider_name == "hetzner" && local.region_input != "" ? local.region_input : "nbg1"

  # Hetzner stacks get an hcloud provider in addition to aws, for the same
  # reason Civo stacks get theirs. The token is read from HCLOUD_TOKEN by the
  # provider itself and is deliberately never written here, so it cannot reach
  # the generated file or the state.
  hetzner_stack = contains(["persistent-hetzner", "cluster-hetzner"], local.raw_class)

  hcloud_provider = local.hetzner_stack ? "\nprovider \"hcloud\" {}" : ""
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
}${local.civo_provider}${local.hcloud_provider}
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
