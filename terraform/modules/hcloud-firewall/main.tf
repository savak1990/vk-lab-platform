locals {
  anywhere = ["0.0.0.0/0", "::/0"]
}

# Inbound only. One "out" rule would flip outbound to default-deny, which
# breaks DNS and the k3s download while cloud-init is still running.
#
# The join, flannel's VXLAN, etcd and the kubelet all speak over the private
# network, which a Hetzner firewall does not filter, so none of them needs a
# rule. Nor do NodePorts: the load balancer reaches nodes privately too.
resource "hcloud_firewall" "this" {
  name = "${var.project}-nodes"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = local.anywhere
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = local.anywhere
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = local.anywhere
  }

  # Selects every platform server, not only the ones Terraform creates, so an
  # autoscaled node is firewalled the moment it exists. Narrowing this to
  # lifecycle=disposable would silently stop covering such a node if its
  # template ever dropped that label.
  apply_to {
    label_selector = "project=${var.project},scope=platform"
  }

  labels = {
    project    = var.project
    scope      = "platform"
    lifecycle  = "disposable"
    managed_by = "terraform"
  }
}

resource "aws_ssm_parameter" "firewall_id" {
  name        = "/${var.project}/cluster-hetzner/firewall/firewall_id"
  type        = "String"
  value       = hcloud_firewall.this.id
  description = "This project's Hetzner cluster firewall ID."
}
