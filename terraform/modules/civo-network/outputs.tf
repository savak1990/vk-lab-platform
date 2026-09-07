output "network_id" {
  value = local.network_id
}

output "cluster_firewall_id" {
  value = var.create_firewalls ? civo_firewall.cluster[0].id : null
}

output "lb_firewall_id" {
  value = var.create_firewalls ? civo_firewall.lb[0].id : null
}
