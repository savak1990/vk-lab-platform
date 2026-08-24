output "volume_ids" {
  description = "EBS volume IDs, in the same order as availability_zones."
  value       = aws_ebs_volume.this[*].id
}

output "azs" {
  description = "Each volume's availability zone, in the same order as volume_ids."
  value       = aws_ebs_volume.this[*].availability_zone
}
