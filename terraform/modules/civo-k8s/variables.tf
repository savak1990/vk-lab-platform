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
