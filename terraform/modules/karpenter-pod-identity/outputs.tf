output "controller_role_arn" {
  value = aws_iam_role.controller.arn
}

output "node_role_name" {
  value = aws_iam_role.node.name
}
