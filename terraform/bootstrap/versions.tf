terraform {
  required_version = ">= 1.16.4, < 1.17.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "= 3.3.0"
    }
  }
}
