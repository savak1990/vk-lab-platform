variable "bucket_name" {
  description = "Globally-unique name for the Terraform remote state bucket."
  type        = string
}

variable "force_destroy" {
  description = "Whether to allow destroying the bucket even if it still contains objects. Defaults to false: the only supported teardown path (make state-down) bypasses Terraform entirely and empties the bucket itself first, so a plain `terragrunt destroy` here should never succeed against a non-empty bucket by default."
  type        = bool
  default     = false
}
