variable "size_gb" {
  description = "Initial volume size in GiB. Only read at creation time — see the ignore_changes note on the volume resource; grow the volume through the consuming Kubernetes operator's CR instead of here."
  type        = number
}

variable "availability_zone" {
  type = string
}

variable "component" {
  description = "Identifies which workload this volume belongs to (e.g. \"postgres\"), independent of any Kubernetes-side tagging."
  type        = string
}
