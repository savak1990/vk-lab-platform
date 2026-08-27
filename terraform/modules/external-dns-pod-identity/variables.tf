variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID ExternalDNS is allowed to manage records in (the lab.<root-domain> zone from persistent/route53)."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name ExternalDNS uses (must match the Helm release's serviceAccount.name)."
  type        = string
  default     = "external-dns"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace ExternalDNS runs in."
  type        = string
  default     = "kube-system"
}
