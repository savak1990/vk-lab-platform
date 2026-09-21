variable "project" {
  description = "PROJECT_NAME - names the network and builds this project's SSM parameter path."
  type        = string
}

variable "ip_range" {
  description = "The private network's IPv4 range. Must not overlap the k3s pod and service CIDRs."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_ip_range" {
  description = "The cloud subnet's IPv4 range, inside ip_range. Servers take their private addresses from here."
  type        = string
  default     = "10.0.1.0/24"
}

variable "network_zone" {
  description = "The hcloud network zone. Networks, load-balancer targets and floating IPs must all stay inside one zone."
  type        = string
  default     = "eu-central"
}
