include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/route53-zone"
}

locals {
  project             = get_env("PROJECT_NAME", "vk-lab-platform")
  project_region      = get_env("PROJECT_REGION", "eu-west-1")
  account_main_region = get_env("ACCOUNT_MAIN_REGION", "eu-west-1")

  # Prefer the already-recorded subdomain over the env var, so a forgotten
  # SUBDOMAIN re-export on a later apply can't silently move this zone.
  # Falls back to the env var/default only on the first-ever apply.
  # Distinguishes "not written yet" (ParameterNotFound) and "no credentials
  # configured" (a credential-free `terragrunt validate`) - both fall back
  # to the env var below - from any other AWS error (expired/invalid
  # credentials, throttling - abort the whole apply loudly). A blanket
  # `|| true` would swallow all of these alike, silently reproducing the
  # exact drift this parameter exists to prevent.
  recorded_subdomain = run_cmd(
    "--terragrunt-quiet",
    "bash", "-c",
    "out=$(aws ssm get-parameter --name /${local.project}/bootstrap/route53/subdomain --region ${local.project_region} --query Parameter.Value --output text 2>&1); rc=$?; if [ $rc -ne 0 ]; then case \"$out\" in *ParameterNotFound*|*\"Unable to locate credentials\"*|*NoCredentialProviders*) exit 0 ;; *) echo \"$out\" >&2; exit 1 ;; esac; fi; printf '%s' \"$out\""
  )
  subdomain = local.recorded_subdomain != "" ? local.recorded_subdomain : get_env("SUBDOMAIN", "lab")
}

inputs = {
  project             = local.project
  subdomain           = local.subdomain
  account_main_region = local.account_main_region
}
