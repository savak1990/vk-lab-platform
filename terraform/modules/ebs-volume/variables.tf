variable "volume_count" {
  description = "Number of EBS volumes to create, one per stateful-workload replica (e.g. one per Kafka broker)."
  type        = number
  default     = 1
}

variable "availability_zone" {
  description = "AZ for every volume in the list - the platform pins all stateful workloads and the node group to one shared AZ (see terraform/live/root.hcl's storage_az/postgres_az local)."
  type        = string
}

variable "size_gb" {
  description = "Size, in GiB, for every volume in the list. Only read at creation time - see the module's ignore_changes note."
  type        = number
}

variable "component" {
  description = "Value for this volume's Component tag, e.g. \"kafka\"."
  type        = string
}
