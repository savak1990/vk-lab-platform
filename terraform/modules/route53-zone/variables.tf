variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter paths."
  type        = string
}

variable "subdomain" {
  description = "Subdomain delegated from the root domain for this platform, e.g. \"lab\" in lab.<root-domain>."
  type        = string
  default     = "lab"
}

variable "negative_cache_ttl" {
  description = "SOA minimum field for this zone: how long resolvers may cache an NXDOMAIN for any name under it. Route53's own zone default is 86400s (24h), which makes a freshly created record look broken to any resolver that already cached its NXDOMAIN."
  type        = number
  default     = 300
}
