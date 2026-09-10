# CIVO-020 verified on a live LON1 cluster: 1.35.0-k3s1 was the only k3s
# version both stable and Default=true on the spike date. Pin it explicitly
# rather than relying on the provider's own default, since that default
# tracks Civo's own "Default" flag and would silently change under us.
resource "civo_kubernetes_cluster" "this" {
  name               = var.project
  cluster_type       = "k3s"
  cni                = "flannel"
  kubernetes_version = "1.35.0-k3s1"
  network_id         = var.network_id
  firewall_id        = var.firewall_id

  # Traefik removed; metrics-server's "-metrics-server" token is deliberately
  # omitted - CIVO-020 verified it is inert (metrics-server is built_in:
  # true, which the API does not let this field remove), and a future Civo
  # change that made the token start working would then remove
  # metrics-server without warning and break kubectl top/HPA.
  applications = "-traefik2-nodeport"

  write_kubeconfig = false
  tags             = "Project=${var.project} Scope=platform Lifecycle=disposable ManagedBy=terraform"

  pools {
    label      = "workers"
    size       = "g4s.kube.medium"
    node_count = 3
  }

  # Civo's create API accepts tags but its update API rejects them
  # (400 invalid_parameter_name) - without this, every apply after the
  # first tries to "fix" the resulting drift and fails.
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "aws_ssm_parameter" "cluster_id" {
  name        = "/${var.project}/cluster-civo/k8s/cluster_id"
  type        = "String"
  value       = civo_kubernetes_cluster.this.id
  description = "This disposable run's Civo Kubernetes cluster ID."
}

resource "aws_ssm_parameter" "api_endpoint" {
  name        = "/${var.project}/cluster-civo/k8s/api_endpoint"
  type        = "String"
  value       = civo_kubernetes_cluster.this.api_endpoint
  description = "This disposable run's Civo Kubernetes API endpoint."
}
