# Logical "object-storage" on CoreWeave AI Object Storage: a private bucket in one zone with
# optional versioning and an expiration rule. Bucket names are global, so the organization id
# is appended. Tiering is automatic (by access pattern), so the template tier is not mapped.

variable "name" { type = string }
variable "zone" { type = string }
variable "versioning" {
  type    = bool
  default = false
}
variable "retention_days" {
  type    = number
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

data "coreweave_caller_identity" "current" {}

locals {
  org    = replace(lower(data.coreweave_caller_identity.current.organization_id), "/[^a-z0-9-]/", "")
  bucket = trim(substr("${var.name}-${local.org}", 0, 63), "-")
}

resource "coreweave_object_storage_bucket" "this" {
  name = local.bucket
  zone = var.zone
  tags = var.tags
}

resource "coreweave_object_storage_bucket_versioning" "this" {
  count  = var.versioning ? 1 : 0
  bucket = coreweave_object_storage_bucket.this.name
  versioning_configuration {
    status = "Enabled"
  }
}

resource "coreweave_object_storage_bucket_lifecycle_configuration" "this" {
  count  = var.retention_days == null ? 0 : 1
  bucket = coreweave_object_storage_bucket.this.name
  rule {
    id     = "orkstage-retention"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = var.retention_days
    }
  }
}

output "kind" { value = "object-storage" }
output "bucket" { value = coreweave_object_storage_bucket.this.name }
output "endpoint" { value = "https://cwobject.com" }
output "lota_endpoint" { value = "http://cwlota.com" }
output "region" { value = var.zone }
