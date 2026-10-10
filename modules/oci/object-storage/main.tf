# Logical "object-storage" on OCI Object Storage: a bucket encrypted with Oracle managed keys,
# private unless asked otherwise, with optional versioning, tiering and an expiry rule.

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "namespace" { type = string }
variable "region" { type = string }
variable "versioning" {
  type    = bool
  default = false
}
variable "tier" {
  type    = string
  default = "standard"
  validation {
    condition     = contains(["standard", "infrequent", "archive"], var.tier)
    error_message = "tier must be standard, infrequent or archive."
  }
}
variable "public_access" {
  type    = bool
  default = false
}
variable "retention_days" {
  type    = number
  default = null
}
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

resource "oci_objectstorage_bucket" "this" {
  compartment_id = var.compartment_id
  namespace      = var.namespace
  name           = var.name
  access_type    = var.public_access ? "ObjectRead" : "NoPublicAccess"
  storage_tier   = var.tier == "archive" ? "Archive" : "Standard"
  # Infrequent access objects are placed by auto tiering; Archive is a bucket level tier.
  auto_tiering  = var.tier == "infrequent" ? "InfrequentAccess" : "Disabled"
  versioning    = var.versioning ? "Enabled" : "Disabled"
  freeform_tags = var.freeform_tags
}

# Needs a policy that lets the Object Storage service manage objects in the compartment.
resource "oci_objectstorage_object_lifecycle_policy" "this" {
  count     = var.retention_days == null ? 0 : 1
  namespace = var.namespace
  bucket    = oci_objectstorage_bucket.this.name
  rules {
    name        = "orkstage-expiry"
    action      = "DELETE"
    target      = "objects"
    is_enabled  = true
    time_amount = tostring(var.retention_days)
    time_unit   = "DAYS"
  }
}

output "kind" { value = "object-storage" }
output "bucket" { value = oci_objectstorage_bucket.this.name }
output "namespace" { value = var.namespace }
output "region" { value = var.region }
output "endpoint" { value = "https://objectstorage.${var.region}.oraclecloud.com/n/${var.namespace}/b/${oci_objectstorage_bucket.this.name}" }
output "s3_endpoint" { value = "https://${var.namespace}.compat.objectstorage.${var.region}.oraclecloud.com" }
