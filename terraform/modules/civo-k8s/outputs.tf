output "cluster_id" {
  value = civo_kubernetes_cluster.this.id
}

output "api_endpoint" {
  value = civo_kubernetes_cluster.this.api_endpoint
}

output "cluster_name" {
  value = civo_kubernetes_cluster.this.name
}
