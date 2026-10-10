terraform {
  required_version = ">= 1.11"
  required_providers {
    vultr = { source = "vultr/vultr", version = "~> 2.30" }
  }
}
