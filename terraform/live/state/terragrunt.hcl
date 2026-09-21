# The "state" lifecycle layer, one level below Bootstrap: the bucket every
# other unit stores its own Terraform state in. make state-up handles this
# unit's own first-run bootstrap, so this file never needs manual editing.

include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read state_bucket below.
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/terraform-state"
}

inputs = {
  # The same local every other unit's backend resolves to, rather than a
  # second copy of the naming rule: a bucket created under one name and
  # written to under another fails only at the migration step, after the
  # first name already exists.
  bucket_name = include.root.locals.state_bucket
}
