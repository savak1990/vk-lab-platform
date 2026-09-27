output "user_pool_id" {
  description = "Cognito user pool id. A public identifier."
  value       = aws_cognito_user_pool.this.id
}

output "client_id" {
  description = "Cognito app client id. A public identifier."
  value       = aws_cognito_user_pool_client.app.id
}

output "issuer" {
  description = "OIDC issuer URL the application's JWT verifier fetches JWKS from."
  value       = local.issuer
}

output "region" {
  description = "Region the pool lives in. The Amplify client needs it beside the pool id."
  value       = data.aws_region.current.region
}
