variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role created for this controller."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name the controller uses (must match the Helm release's serviceAccount.name)."
  type        = string
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the controller runs in."
  type        = string
}
