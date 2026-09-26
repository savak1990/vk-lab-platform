data "aws_region" "current" {}

locals {
  issuer     = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
  ssm_prefix = "/${var.project}/persistent/ahorro-cognito"
}

# Deletion protection stays off: the AWS API refuses DeleteUserPool on a
# protected pool, so a teardown would fail and leak one pool per run.
# CONFIRM_DESTROY on persistent-down is the guard.
resource "aws_cognito_user_pool" "this" {
  name                     = "${var.project}-ahorro"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }
}

# One client: the application's verifier pins a single client id, so a second
# client would mint tokens its own service refuses. The non-admin
# ALLOW_USER_PASSWORD_AUTH stays off - the public client id could call it.
resource "aws_cognito_user_pool_client" "app" {
  name            = "vk-ahorro-app"
  user_pool_id    = aws_cognito_user_pool.this.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers  = ["COGNITO"]
  prevent_user_existence_errors = "ENABLED"

  id_token_validity      = 1
  access_token_validity  = 1
  refresh_token_validity = 30

  token_validity_units {
    id_token      = "hours"
    access_token  = "hours"
    refresh_token = "days"
  }
}

data "aws_kms_secrets" "this" {
  secret {
    name    = "test_user_password"
    payload = filebase64(var.test_user_password_secret_path)
  }
}

# SUPPRESS stops Cognito mailing an invitation to an address that does not
# exist, and setting password rather than temporary_password leaves the user
# CONFIRMED so a scripted sign-in needs no password-change challenge.
resource "aws_cognito_user" "test" {
  user_pool_id   = aws_cognito_user_pool.this.id
  username       = var.test_user_email
  password       = data.aws_kms_secrets.this.plaintext["test_user_password"]
  message_action = "SUPPRESS"

  attributes = {
    email          = var.test_user_email
    email_verified = "true"
    name           = "e2e"
  }
}

# Public identifiers. The application repository is public and may commit
# these; they are published here so a consumer reads them per project instead.
resource "aws_ssm_parameter" "user_pool_id" {
  name        = "${local.ssm_prefix}/user_pool_id"
  value       = aws_cognito_user_pool.this.id
  type        = "String"
  description = "Ahorro Cognito user pool id."
}

resource "aws_ssm_parameter" "client_id" {
  name        = "${local.ssm_prefix}/client_id"
  value       = aws_cognito_user_pool_client.app.id
  type        = "String"
  description = "Ahorro Cognito app client id."
}

resource "aws_ssm_parameter" "issuer" {
  name        = "${local.ssm_prefix}/issuer"
  value       = local.issuer
  type        = "String"
  description = "Ahorro Cognito issuer URL; the application derives its JWKS endpoint from it."
}

resource "aws_ssm_parameter" "test_user_email" {
  name        = "${local.ssm_prefix}/test_user_email"
  value       = var.test_user_email
  type        = "String"
  description = "Username of the Ahorro end-to-end test user."
}

resource "aws_ssm_parameter" "test_user_password" {
  name        = "${local.ssm_prefix}/test_user_password"
  value       = data.aws_kms_secrets.this.plaintext["test_user_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Password of the Ahorro end-to-end test user, so a scripted sign-in needs no ciphertext file."
}
