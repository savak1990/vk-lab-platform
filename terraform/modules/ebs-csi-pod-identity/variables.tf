variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name the EBS CSI controller uses (must match the Helm release's controller.serviceAccount.name)."
  type        = string
  default     = "ebs-csi-controller-sa"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the EBS CSI controller runs in."
  type        = string
  default     = "kube-system"
}
