variable "cidr_block" {
  description = "VPC CIDR. Default avoids overlapping this AWS account's default VPC (172.31.0.0/16)."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to create one public subnet in each. Must include the region's postgres_az (root.hcl, ADR 0013) so the EKS node group's AZ still matches where the Postgres EBS snapshot restores."
  type        = list(string)
}
