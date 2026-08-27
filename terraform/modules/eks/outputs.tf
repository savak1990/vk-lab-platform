output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "node_group_iam_role_arn" {
  value = module.eks.eks_managed_node_groups["system"].iam_role_arn
}

output "cluster_iam_role_arn" {
  value = module.eks.cluster_iam_role_arn
}

output "node_subnet_id" {
  value = local.node_subnet_id
}

output "control_plane_subnet_ids" {
  value = data.aws_subnets.default.ids
}

output "vpc_id" {
  value = data.aws_vpc.default.id
}
