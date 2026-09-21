resource "hcloud_network" "this" {
  name     = var.project
  ip_range = var.ip_range

  labels = {
    project    = var.project
    scope      = "platform"
    lifecycle  = "persistent"
    managed_by = "terraform"
  }
}

# The hcloud API exposes no labels on a subnet, so the four identification
# labels stop at the network that owns it.
resource "hcloud_network_subnet" "this" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_ip_range
}

resource "aws_ssm_parameter" "network_id" {
  name        = "/${var.project}/persistent-hetzner/network/network_id"
  type        = "String"
  value       = hcloud_network.this.id
  description = "This project's Hetzner private network ID."
}

resource "aws_ssm_parameter" "subnet_ip_range" {
  name        = "/${var.project}/persistent-hetzner/network/subnet_ip_range"
  type        = "String"
  value       = hcloud_network_subnet.this.ip_range
  description = "This project's Hetzner cloud subnet IPv4 range."
}
