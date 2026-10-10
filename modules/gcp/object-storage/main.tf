# Logical "object-storage" on Cloud Storage: uniform bucket level access, public access
# prevention unless asked otherwise, optional versioning and lifecycle rules.

variable "name" { type = string } # globally unique bucket name
variable "location" { type = string }
variable "tier" {
  type    = string
  default = "standard"
  validation {
    condition     = contains(["standard", "infrequent", "archive"], var.tier)
    error_message = "tier must be standard, infrequent or archive."
  }
}
variable "versioning" {
  type    = bool
  default = false
}
variable "public_access" {
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

resource "google_storage_bucket" "this" {
  name                        = var.name
  location                    = upper(var.location)
  force_destroy               = var.force_destroy
  uniform_bucket_level_access = true
  public_access_prevention    = var.public_access ? "inherited" : "enforced"

  versioning {
    enabled = var.versioning
  }

  dynamic "lifecycle_rule" {
    for_each = var.tier == "standard" ? [] : [1]
    content {
      condition {
        age = 30
      }
      action {
        type          = "SetStorageClass"
        storage_class = var.tier == "archive" ? "ARCHIVE" : "NEARLINE"
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.retention_days == null ? [] : [1]
    content {
      condition {
        age = var.retention_days
      }
      action {
        type = "Delete"
      }
    }
  }
}

resource "google_storage_bucket_iam_member" "public_read" {
  count  = var.public_access ? 1 : 0
  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

output "kind" { value = "object-storage" }
output "bucket" { value = google_storage_bucket.this.name }
output "endpoint" { value = "https://storage.googleapis.com/${google_storage_bucket.this.name}" }
output "region" { value = var.location }
