# The Civo provider exposes no tags argument on any resource here, so the
# constitution's Project/Scope/Lifecycle/ManagedBy tags cannot be carried.
resource "civo_network" "this" {
  count = var.create_network ? 1 : 0
  label = var.project
}

# civo_network.this is a Persistent-lifecycle resource and Civo network
# assignment is permanent (decisions.md) - a plan that proposed destroy+
# recreate here instead of an address change would be expensive to undo.
# Pre-empt that rather than reacting to it after the fact.
moved {
  from = civo_network.this
  to   = civo_network.this[0]
}

locals {
  network_id = var.create_network ? civo_network.this[0].id : var.network_id
}

resource "aws_ssm_parameter" "network_id" {
  count       = var.create_network ? 1 : 0
  name        = "/${var.project}/persistent-civo/network/id"
  type        = "String"
  value       = local.network_id
  description = "This project's Civo network ID."
}

moved {
  from = aws_ssm_parameter.network_id
  to   = aws_ssm_parameter.network_id[0]
}

# Default-deny (Civo: "the default for a new firewall is to deny everything").
# Only 6443 is opened because GitHub Actions runners have no fixed IP to
# allowlist instead. All other ports (kubelet 10250, NodePort range, ...)
# stay blocked by the firewall default, not by anything in this file.
resource "civo_firewall" "cluster" {
  count                = var.create_firewalls ? 1 : 0
  name                 = "${var.project}-k8s"
  network_id           = local.network_id
  create_default_rules = false

  ingress_rule {
    label      = "k3s-api"
    protocol   = "tcp"
    port_range = "6443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  # Both TCP and UDP egress are required, not just TCP: firewalls default-deny,
  # and without UDP/53 egress nodes cannot resolve DNS at all (no registry
  # pulls, no cluster bootstrap) - the whole cluster fails to reach Ready.
  egress_rule {
    label      = "all-egress-tcp"
    protocol   = "tcp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-udp"
    protocol   = "udp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }
}

# Bound to nothing yet - CIVO-060's Envoy Service annotates
# kubernetes.civo.com/firewall-id to attach its LoadBalancer here. Without
# that annotation, Civo would otherwise auto-create its own firewall for any
# LoadBalancer Service, open to all TCP/UDP from 0.0.0.0/0 - CIVO-020 observed
# this happen even with this cluster firewall's create_default_rules = false.
resource "civo_firewall" "lb" {
  count                = var.create_firewalls ? 1 : 0
  name                 = "${var.project}-lb"
  network_id           = local.network_id
  create_default_rules = false

  ingress_rule {
    label      = "http"
    protocol   = "tcp"
    port_range = "80"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  ingress_rule {
    label      = "https"
    protocol   = "tcp"
    port_range = "443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-tcp"
    protocol   = "tcp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-udp"
    protocol   = "udp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }
}

resource "aws_ssm_parameter" "cluster_firewall_id" {
  count       = var.create_firewalls ? 1 : 0
  name        = "/${var.project}/cluster-civo/network/cluster_firewall_id"
  type        = "String"
  value       = civo_firewall.cluster[0].id
  description = "This disposable run's Civo cluster firewall ID."
}

resource "aws_ssm_parameter" "lb_firewall_id" {
  count       = var.create_firewalls ? 1 : 0
  name        = "/${var.project}/cluster-civo/network/lb_firewall_id"
  type        = "String"
  value       = civo_firewall.lb[0].id
  description = "This disposable run's Civo LB firewall ID, for CIVO-060's Envoy Service annotation."
}
