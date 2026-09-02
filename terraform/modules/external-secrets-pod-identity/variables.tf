variable "cluster_name" {
  description = "EKS cluster name the pod identity association targets."
  type        = string
}

variable "project" {
  description = "PROJECT_NAME - used to build the SSM parameter ARNs External Secrets Operator is allowed to read."
  type        = string
}

variable "account_main_region" {
  description = "ACCOUNT_MAIN_REGION - where alias/lab-secrets actually lives, independent of this unit's own provider region (PROJECT_REGION)."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name the External Secrets Operator controller uses (must match the Helm release's serviceAccount.name)."
  type        = string
  default     = "external-secrets"
}

variable "service_account_namespace" {
  description = "Kubernetes namespace the External Secrets Operator controller runs in."
  type        = string
  default     = "external-secrets"
}
