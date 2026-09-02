variable "fqdn" {
  description = "Fully-qualified domain name the certificate is issued for, e.g. lab.<root-domain>."
  type        = string
}

variable "zone_id" {
  description = "Route 53 zone ID to create DNS validation records in (the delegated subdomain's own zone, not the parent zone)."
  type        = string
}

variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter path."
  type        = string
}
