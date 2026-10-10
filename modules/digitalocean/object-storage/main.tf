# Logical "object-storage" on DigitalOcean Spaces: a private bucket (public read only when asked),
# optional versioning and an expiration lifecycle. Spaces has a single storage class, so the
# template tier does not change the bucket.

variable "name" { type = string } # globally unique, 3 to 63 chars
variable "region" { type = string }
variable "versioning" {
  type    = bool
  default = false
}
variable "public_read" {
  type    = bool
  default = false
}
variable "retention_days" {
  type    = number
  default = null
}
variable "force_destroy" {
  type    = bool
  default = false
}

resource "digitalocean_spaces_bucket" "this" {
  name          = var.name
  region        = var.region
  acl           = var.public_read ? "public-read" : "private"
  force_destroy = var.force_destroy

  versioning {
    enabled = var.versioning
  }

  dynamic "lifecycle_rule" {
    for_each = var.retention_days == null ? [] : [1]
    content {
      id                                     = "orkstage-retention"
      enabled                                = true
      abort_incomplete_multipart_upload_days = 7
      expiration {
        days = var.retention_days
      }
      dynamic "noncurrent_version_expiration" {
        for_each = var.versioning ? [1] : []
        content {
          days = var.retention_days
        }
      }
    }
  }
}

output "kind" { value = "object-storage" }
output "bucket" { value = digitalocean_spaces_bucket.this.name }
output "region" { value = digitalocean_spaces_bucket.this.region }
output "endpoint" { value = "https://${digitalocean_spaces_bucket.this.region}.digitaloceanspaces.com" }
output "bucket_domain_name" { value = digitalocean_spaces_bucket.this.bucket_domain_name }
output "urn" { value = digitalocean_spaces_bucket.this.urn }
