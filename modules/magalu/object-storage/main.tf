# Logical "object-storage" on Magalu Cloud Object Storage (S3 compatible). Buckets are private;
# versioning is optional. The provider authenticates bucket calls with the object storage key pair.

variable "name" { type = string } # bucket name, 3 to 63 lowercase characters
variable "region" { type = string }
variable "versioning" {
  type    = bool
  default = false
}

resource "mgc_object_storage_buckets" "this" {
  bucket     = var.name
  versioning = var.versioning
}

output "kind" { value = "object-storage" }
output "bucket" { value = mgc_object_storage_buckets.this.bucket }
output "region" { value = var.region }
output "endpoint" { value = "https://${var.region}.magaluobjects.com" }
