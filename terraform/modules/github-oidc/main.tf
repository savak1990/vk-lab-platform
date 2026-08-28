# thumbprint_list is intentionally unset: AWS validates this issuer against its
# own trusted CA library and computes the value, so pinning a SHA-1 here would
# only create a fingerprint that rots when GitHub rotates certificates.
resource "aws_iam_openid_connect_provider" "this" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
