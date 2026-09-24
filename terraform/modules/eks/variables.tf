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

  validation {
    condition     = contains(keys(var.public_subnet_ids_by_az), var.availability_zone)
    error_message = "No subnet for this AZ in public_subnet_ids_by_az - does the persistent vpc unit cover it?"
  }
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

variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter path."
  type        = string
}

variable "min_worker_nodes" {
  description = "MIN_WORKER_NODES - size of the fixed system node group. Karpenter supplies every worker above it, bounded by MAX_WORKER_NODES as a NodePool cpu limit, so this is not the cluster's total."
  type        = number
  default     = 1

  validation {
    condition     = var.min_worker_nodes > 0
    error_message = "min_worker_nodes must be a positive integer."
  }
}

variable "worker_node_type" {
  description = "WORKER_NODE_TYPE - instance type for the system node group. Validated against scripts/lib/catalog.sh before Terraform runs; pod density per type is spec 028."
  type        = string
  default     = "t4g.medium"
}
