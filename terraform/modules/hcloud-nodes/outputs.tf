output "control_plane_ip" {
  value = hcloud_server.control_plane.ipv4_address
}

output "control_plane_private_ip" {
  value = local.cp_private_ip
}

output "worker_ips" {
  value = hcloud_server.worker[*].ipv4_address
}

output "server_ids" {
  value = concat([hcloud_server.control_plane.id], hcloud_server.worker[*].id)
}
