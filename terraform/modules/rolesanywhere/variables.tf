variable "project" {
  description = "PROJECT_NAME - used to build resource names and the SSM parameter ARNs the eso consumer is allowed to read."
  type        = string
}

variable "provider_region" {
  description = "The provider's own region, lowercased - the backup bucket carries it in its name, so the grant must too or every write is denied."
  type        = string
}

variable "ca_cert_pem" {
  description = "PEM content of the workload root CA certificate. Empty string means this project has no Roles Anywhere trust chain - no resources are created."
  type        = string
}

variable "provider_name" {
  description = "Infrastructure provider whose trust chain this is (civo, hetzner). Names every object in the chain, so it must match the CN inside ca_cert_pem."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID for the external-dns consumer's policy."
  type        = string
}

variable "x509_issuer_cn" {
  description = "CN that must appear in x509Issuer/CN on presented client certs. Null computes it as \"$${project}-$${provider_name}-workload-ca\" (the root CA's own Subject CN)."
  type        = string
  default     = null
}

variable "session_duration" {
  description = "Roles Anywhere profile session duration in seconds."
  type        = number
  default     = 3600
}
