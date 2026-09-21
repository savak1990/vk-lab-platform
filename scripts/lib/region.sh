# The platform targets exactly one region. Deliberately not named AWS_REGION
# and deliberately not exported: an exported AWS_REGION would let the AWS CLI
# resolve a region ambiently and collide with the operator's own profile.

LAB_REGION="eu-west-1"

# AWS CLI v2 pipes output through a pager on a terminal, which stops a script
# dead at (END). Every script that sources this one runs unattended.
export AWS_PAGER=""

# Civo's region constant. Also declared in terraform/live/root.hcl
# (civo_region) - Terraform and shell each need their own copy since one
# isn't reachable from the other; never derive this value, keep both literal.
CIVO_REGION="LON1"

# Hetzner's location and network zone. Also declared in
# terraform/live/root.hcl (hcloud_location) - Terraform and shell each need
# their own copy since one isn't reachable from the other; never derive these
# values, keep both literal.
HCLOUD_LOCATION="nbg1"
HCLOUD_NETWORK_ZONE="eu-central"
