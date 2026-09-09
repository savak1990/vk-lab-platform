output "trust_anchor_arn" {
  value = try(aws_rolesanywhere_trust_anchor.this[0].arn, null)
}

output "profile_arn" {
  value = try(aws_rolesanywhere_profile.this[0].arn, null)
}

output "role_arns" {
  value = { for k, r in aws_iam_role.consumer : k => r.arn }
}
