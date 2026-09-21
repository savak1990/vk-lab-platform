resource "hcloud_ssh_key" "this" {
  name       = var.project
  public_key = var.public_key

  labels = {
    project    = var.project
    scope      = "platform"
    lifecycle  = "persistent"
    managed_by = "terraform"
  }
}

resource "aws_ssm_parameter" "ssh_key_id" {
  name        = "/${var.project}/persistent-hetzner/ssh-key/ssh_key_id"
  type        = "String"
  value       = hcloud_ssh_key.this.id
  description = "This project's Hetzner SSH key ID, attached to every server at creation."
}
