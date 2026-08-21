output "volume_id" {
  value = aws_ebs_volume.this.id
}

output "availability_zone" {
  value = aws_ebs_volume.this.availability_zone
}

# Reflects var.size_gb, not the resource's live attribute — ignore_changes
# means Terraform never observes growth CNPG applies after creation.
output "size_gb" {
  value = var.size_gb
}
