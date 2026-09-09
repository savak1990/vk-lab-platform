variable "project" {
  description = "PROJECT_NAME - used to build resource names and the SSM parameter ARNs the eso consumer is allowed to read."
  type        = string
}

variable "ca_cert_pem" {
  description = "PEM content of the Civo workload root CA certificate. Empty string means this is not a Civo project - no resources are created."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for the external-dns consumer's policy."
  type        = string
}

variable "x509_issuer_cn" {
  description = "CN that must appear in x509Issuer/CN on presented client certs. Null computes it as \"$${project}-civo-workload-ca\" (the root CA's own Subject CN)."
  type        = string
  default     = null
}

variable "session_duration" {
  description = "Roles Anywhere profile session duration in seconds."
  type        = number
  default     = 3600
}
