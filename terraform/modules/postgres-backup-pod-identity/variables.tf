variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "project" {
  description = "PROJECT_NAME - used to build the backup bucket ARN the Postgres instance pods may write to."
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
