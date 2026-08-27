variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name the AWS Load Balancer Controller uses (must match the Helm release's serviceAccount.name)."
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the AWS Load Balancer Controller runs in."
  type        = string
  default     = "kube-system"
}
