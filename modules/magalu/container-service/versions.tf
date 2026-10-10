terraform {
  required_version = ">= 1.11"
  required_providers {
    mgc = { source = "MagaluCloud/mgc", version = "~> 0.56.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.1" }
  }
}
