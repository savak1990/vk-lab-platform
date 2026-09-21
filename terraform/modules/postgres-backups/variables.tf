variable "project" {
  description = "PROJECT_NAME - used to build the bucket name and this project's SSM parameter path."
  type        = string
}

variable "force_destroy" {
  description = "Whether to allow destroying the bucket even if it still contains objects. Defaults to false: persistent-down empties the bucket itself before destroying, so a plain `terragrunt destroy` should never succeed against a non-empty bucket by default."
  type        = bool
  default     = false
}

variable "backstop_expiration_days" {
  description = "Age at which the backstop lifecycle rule expires backup objects. Retention is normally enforced by the backup operator inside the cluster; this rule only bounds storage when no cluster is running to prune. Keep it well above the operator's own recovery window."
  type        = number
  default     = 30
}

variable "ssm_layer" {
  description = "Lifecycle directory whose SSM path records the bucket name: persistent (aws) or persistent-civo (civo)."
  type        = string
  default     = "persistent-civo"
}

variable "provider_region" {
  description = "The provider's own region, lowercased - namespaces this project's buckets so two regions never share one. Not where the bucket lives; that is the AWS provider's region."
  type        = string
}
