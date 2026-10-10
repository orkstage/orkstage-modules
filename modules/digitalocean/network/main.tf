# Logical "network" on DigitalOcean: one VPC in the target region. Databases and caches join it
# through private_network_uuid; App Platform apps join it in the regions App Platform supports.

variable "name" { type = string }
variable "region" { type = string }
# Empty lets DigitalOcean pick a range that does not overlap the account's other VPCs.
variable "ip_range" {
  type    = string
  default = ""
}
variable "description" {
  type    = string
  default = "Managed by OrkStage"
}

resource "digitalocean_vpc" "this" {
  name        = var.name
  region      = var.region
  description = var.description
  ip_range    = var.ip_range == "" ? null : var.ip_range
}

output "kind" { value = "network" }
output "network_id" { value = digitalocean_vpc.this.id }
output "vpc_id" { value = digitalocean_vpc.this.id }
output "cidr" { value = digitalocean_vpc.this.ip_range }
output "region" { value = digitalocean_vpc.this.region }
output "urn" { value = digitalocean_vpc.this.urn }
