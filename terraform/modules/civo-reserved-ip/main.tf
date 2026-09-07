# The Civo provider exposes no tags argument on any resource here, so the
# constitution's Project/Scope/Lifecycle/ManagedBy tags cannot be carried.
resource "civo_reserved_ip" "this" {
  name = "${var.project}-ingress"
}

resource "aws_ssm_parameter" "address" {
  name        = "/${var.project}/persistent-civo/reserved-ip/address"
  type        = "String"
  value       = civo_reserved_ip.this.ip
  description = "This project's reserved Civo ingress IP, assigned to the LoadBalancer Service by the kubernetes.civo.com/ipv4-address annotation."
}
