# Logical "object-storage" on Vultr Object Storage: one subscription per resource, so its S3
# keys reach only the services that depend on it, and one bucket inside it. The keys stay in
# state and in the Vultr API; services get a reference (`vultr-objstore://<id>`).

variable "name" { type = string }
# Object storage cluster and tier, picked by the adapter for the region.
variable "cluster_id" { type = number }
variable "tier_id" { type = number }
variable "versioning" {
  type    = bool
  default = false
}

resource "vultr_object_storage" "this" {
  cluster_id = var.cluster_id
  tier_id    = var.tier_id
  label      = var.name
}

resource "vultr_object_storage_bucket" "this" {
  object_storage_id = vultr_object_storage.this.id
  name              = var.name
  enable_versioning = var.versioning
}

output "kind" { value = "object-storage" }
output "id" { value = vultr_object_storage.this.id }
output "bucket" { value = vultr_object_storage_bucket.this.name }
output "endpoint" { value = "https://${vultr_object_storage.this.s3_hostname}" }
output "region" { value = vultr_object_storage.this.region }
output "cluster_id" { value = var.cluster_id }
output "tier_id" { value = var.tier_id }
output "secret_ref" { value = "vultr-objstore://${vultr_object_storage.this.id}" }
