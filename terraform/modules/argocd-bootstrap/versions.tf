terraform {
  required_version = "= 1.15.9"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
  }
}
