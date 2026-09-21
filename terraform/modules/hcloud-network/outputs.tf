output "network_id" {
  value = hcloud_network.this.id
}

output "subnet_id" {
  value = hcloud_network_subnet.this.id
}

output "subnet_ip_range" {
  value = hcloud_network_subnet.this.ip_range
}
