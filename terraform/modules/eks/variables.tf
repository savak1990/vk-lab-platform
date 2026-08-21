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
