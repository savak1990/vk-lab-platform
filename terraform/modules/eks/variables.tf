variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.36"
}

variable "availability_zone" {
  description = "AZ the system/Karpenter node group's subnet is pinned to. Shared with the persistent postgres-volume unit so the node group and the Postgres EBS volume are never in different AZs."
  type        = string
}

variable "vpc_id" {
  description = "From the persistent vpc unit."
  type        = string
}

variable "control_plane_subnet_ids" {
  description = "Subnet IDs across >= 2 AZs for the EKS control plane, from the persistent vpc unit."
  type        = list(string)
}

variable "public_subnet_ids_by_az" {
  description = "AZ -> subnet ID map from the persistent vpc unit, used to pin the node group's subnet to var.availability_zone."
  type        = map(string)
}
