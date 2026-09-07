# The platform targets exactly one region. Deliberately not named AWS_REGION
# and deliberately not exported: an exported AWS_REGION would let the AWS CLI
# resolve a region ambiently and collide with the operator's own profile.

LAB_REGION="eu-west-1"

# Civo's region constant. Also declared in terraform/live/root.hcl
# (civo_region) - Terraform and shell each need their own copy since one
# isn't reachable from the other; never derive this value, keep both literal.
CIVO_REGION="LON1"
