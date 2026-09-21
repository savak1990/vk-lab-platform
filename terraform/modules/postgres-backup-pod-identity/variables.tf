variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "project" {
  description = "PROJECT_NAME - used to build the backup bucket ARN the Postgres instance pods may write to."
  type        = string
}

variable "provider_region" {
  description = "The provider's own region, lowercased - the backup bucket carries it in its name, so the grant must too or every write is denied."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account of the Postgres instance pods. CNPG names it after the Cluster."
  type        = string
  default     = "lab-postgres"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the Postgres Cluster runs in."
  type        = string
  default     = "cnpg-system"
}
