variable "project" {
  description = "PROJECT_NAME - used as the cluster name and to build this project's SSM parameter path."
  type        = string
}

variable "network_id" {
  description = "The persistent Civo network's ID (from persistent-civo/network)."
  type        = string
}

variable "firewall_id" {
  description = "The disposable cluster firewall's ID (from cluster-civo/network)."
  type        = string
}

variable "min_worker_nodes" {
  description = "MIN_WORKER_NODES - worker nodes in the fixed pool. Authoritative only at create time; the cluster autoscaler owns the count afterwards."
  type        = number
  default     = 3

  validation {
    condition     = var.min_worker_nodes > 0
    error_message = "min_worker_nodes must be a positive integer."
  }
}

variable "worker_node_type" {
  description = "WORKER_NODE_TYPE - the Civo size for every node in the pool. Validated against scripts/lib/catalog.sh before Terraform runs."
  type        = string
  default     = "g4s.kube.medium"
}
