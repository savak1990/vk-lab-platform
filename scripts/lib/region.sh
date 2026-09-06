# The platform targets exactly one region. Deliberately not named AWS_REGION
# and deliberately not exported: an exported AWS_REGION would let the AWS CLI
# resolve a region ambiently and collide with the operator's own profile.

LAB_REGION="eu-west-1"
