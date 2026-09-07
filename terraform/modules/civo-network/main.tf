# The Civo provider exposes no tags argument on any resource here, so the
# constitution's Project/Scope/Lifecycle/ManagedBy tags cannot be carried.
resource "civo_network" "this" {
  label = var.project
}

resource "aws_ssm_parameter" "network_id" {
  name        = "/${var.project}/persistent-civo/network/id"
  type        = "String"
  value       = civo_network.this.id
  description = "This project's Civo network ID."
}
