locals {
  worker_count = var.min_worker_nodes

  # Hetzner's gateway is the network's first address, not the subnet's, so
  # .1-.9 stay assignable and .10 is free for a fixed control plane. Derived
  # here once: the agents' K3S_URL must not drift from the subnet.
  cp_private_ip = cidrhost(var.subnet_ip_range, 10)

  common_labels = {
    project    = var.project
    scope      = "platform"
    lifecycle  = "disposable"
    managed_by = "terraform"
  }

  control_plane_user_data = templatefile("${path.module}/templates/control-plane.yaml.tftpl", {
    k3s_version   = var.k3s_version
    token         = random_password.k3s_token.result
    cp_private_ip = local.cp_private_ip
    nic           = var.private_nic
  })

  # Rendered once and reused by every worker and by the SSM parameter the
  # autoscaler reads, so an autoscaled node is identical to a fixed worker by
  # construction. Nothing here may depend on a server's index.
  worker_user_data = templatefile("${path.module}/templates/node.yaml.tftpl", {
    k3s_version   = var.k3s_version
    token         = random_password.k3s_token.result
    cp_private_ip = local.cp_private_ip
    nic           = var.private_nic
  })
}

# k3s derives the cluster CA from this, so no private key enters state. It
# grants node join and nothing else, it travels the private network, and it is
# regenerated on every bring-up.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "hcloud_server" "control_plane" {
  name         = "${var.project}-cp-1"
  server_type  = var.control_plane_node_type
  image        = var.image
  location     = var.location
  ssh_keys     = [var.ssh_key_id]
  firewall_ids = [var.firewall_id]
  user_data    = local.control_plane_user_data

  # IPv4 is not optional: SSM has no IPv6 endpoint and Hetzner sells no
  # managed NAT.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = var.network_id
    ip         = local.cp_private_ip
    alias_ips  = []
  }

  labels = merge(local.common_labels, { role = "control-plane" })

  shutdown_before_deletion = true

  # Replacing this server is cluster loss, so a cloud-init edit or an image
  # rename must never trigger one. A version change ships as a teardown and a
  # fresh bring-up instead.
  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]

    precondition {
      condition     = length(local.control_plane_user_data) < 32768
      error_message = "The control-plane cloud-init exceeds Hetzner's 32 KiB user_data limit."
    }
  }
}

resource "hcloud_server" "worker" {
  count = local.worker_count

  name         = "${var.project}-worker-${count.index + 1}"
  server_type  = var.worker_node_type
  image        = var.image
  location     = var.location
  ssh_keys     = [var.ssh_key_id]
  firewall_ids = [var.firewall_id]
  user_data    = local.worker_user_data

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    network_id = var.network_id
    ip         = cidrhost(var.subnet_ip_range, 11 + count.index)
    alias_ips  = []
  }

  labels = merge(local.common_labels, { role = "worker" })

  shutdown_before_deletion = true

  # No depends_on against the control plane: the agent unit retries until the
  # API answers, so ordering the creates would only lengthen the apply.
  lifecycle {
    ignore_changes = [user_data, image, ssh_keys]

    precondition {
      condition     = length(local.worker_user_data) < 32768
      error_message = "The worker cloud-init exceeds Hetzner's 32 KiB user_data limit."
    }
  }
}

resource "aws_ssm_parameter" "control_plane_ip" {
  name        = "/${var.project}/cluster-hetzner/k8s/control_plane_ip"
  type        = "String"
  value       = hcloud_server.control_plane.ipv4_address
  description = "This project's k3s control-plane public IPv4 address."
}

resource "aws_ssm_parameter" "control_plane_private_ip" {
  name        = "/${var.project}/cluster-hetzner/k8s/control_plane_private_ip"
  type        = "String"
  value       = local.cp_private_ip
  description = "This project's k3s control-plane private IPv4 address, which agents join over."
}

resource "aws_ssm_parameter" "worker_ips" {
  name        = "/${var.project}/cluster-hetzner/k8s/worker_ips"
  type        = "String"
  value       = join(",", hcloud_server.worker[*].ipv4_address)
  description = "This project's fixed k3s worker public IPv4 addresses, comma-separated."
}

resource "aws_ssm_parameter" "server_ids" {
  name        = "/${var.project}/cluster-hetzner/k8s/server_ids"
  type        = "String"
  value       = join(",", concat([hcloud_server.control_plane.id], hcloud_server.worker[*].id))
  description = "This project's Hetzner server IDs, control plane first, comma-separated."
}

# The only SecureString in this stack: the render carries the join token. The
# autoscaler reads it as its node template, so its nodes cannot drift from the
# fixed workers.
resource "aws_ssm_parameter" "worker_user_data" {
  name        = "/${var.project}/cluster-hetzner/k8s/worker_user_data"
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  value       = local.worker_user_data
  description = "This project's rendered k3s worker cloud-init, the cluster autoscaler's node template."
}
