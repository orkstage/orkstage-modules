terraform {
  required_version = ">= 1.11"
  required_providers {
    coreweave  = { source = "coreweave/coreweave", version = "~> 0.24.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.3" }
  }
}
