variable "project" {
  description = "PROJECT_NAME - names every server and builds this project's SSM parameter path."
  type        = string
}

variable "node_count" {
  description = "NODE_COUNT - servers in the fixed pool, the schedulable control plane included. Authoritative only at create time; the cluster autoscaler owns the count afterwards."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count > var.control_plane_count
    error_message = "node_count must leave at least one worker beside the control plane."
  }
}

variable "node_type" {
  description = "NODE_TYPE - the Hetzner server type for every server. Validated against scripts/lib/catalog.sh before Terraform runs."
  type        = string
  default     = "cx33"
}

variable "control_plane_count" {
  description = "Control-plane servers. Locked at 1 until an HA spec exists."
  type        = number
  default     = 1

  validation {
    condition     = var.control_plane_count == 1
    error_message = "An HA control plane needs a stable API address for the agents; see specs/hetzner/decisions.md."
  }
}

variable "location" {
  description = "The Hetzner location every server is created in. Must sit inside the private network's zone."
  type        = string
  default     = "fsn1"
}

variable "image" {
  description = "The Hetzner image name every server boots."
  type        = string
  default     = "ubuntu-24.04"
}

variable "k3s_version" {
  description = "INSTALL_K3S_VERSION for both roles, rendered from one value so a worker can never run a different minor than the control plane."
  type        = string

  # 1.36, not 1.37: cluster-autoscaler publishes no 1.37 tag and the hcloud
  # cloud controller manager supports 1.34 to 1.36.
  default = "v1.36.4+k3s1"
}

variable "private_nic" {
  description = "The private network interface k3s binds the CNI and the node address to."
  type        = string
  default     = "enp7s0"
}

variable "network_id" {
  description = "The persistent private network every server attaches to."
  type        = string
}

variable "subnet_ip_range" {
  description = "The persistent cloud subnet's IPv4 range. Server private addresses are derived from it."
  type        = string
}

variable "ssh_key_id" {
  description = "The persistent SSH key attached to every server at creation. Immutable afterwards."
  type        = string
}

variable "firewall_id" {
  description = "The cluster firewall attached to every server at creation."
  type        = string
}
