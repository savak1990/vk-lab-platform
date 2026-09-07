terraform {
  required_version = "= 1.15.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.60.0"
    }
    civo = {
      source  = "civo/civo"
      version = "= 1.3.2"
    }
  }
}
