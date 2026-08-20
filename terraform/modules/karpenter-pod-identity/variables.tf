variable "cluster_name" {
  description = "EKS cluster name the pod identity association and node role target."
  type        = string
}

variable "node_subnet_id" {
  description = "Subnet ID Karpenter-provisioned nodes should launch into (the same fixed subnet the system node group uses)."
  type        = string
}

variable "node_security_group_id" {
  description = "Security group ID Karpenter-provisioned nodes should use (the EKS module's shared node security group)."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name the Karpenter controller uses (must match the Helm release's serviceAccount.name)."
  type        = string
  default     = "karpenter"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the Karpenter controller runs in."
  type        = string
  default     = "kube-system"
}
