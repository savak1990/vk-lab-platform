output "ssh_key_id" {
  value = hcloud_ssh_key.this.id
}

output "fingerprint" {
  value = hcloud_ssh_key.this.fingerprint
}
