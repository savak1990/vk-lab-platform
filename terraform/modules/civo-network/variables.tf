variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter path."
  type        = string
}

variable "create_network" {
  description = "Create the civo_network resource. False when this unit only adds firewalls to an existing network (see network_id)."
  type        = bool
  default     = true
}

variable "create_firewalls" {
  description = "Create the disposable cluster/LB firewalls. False for the persistent network unit."
  type        = bool
  default     = false
}

variable "network_id" {
  description = "An existing network's ID, required when create_network = false."
  type        = string
  default     = null
}
