# Logical "network" on Vultr: one VPC in the region. Vultr regions have no availability zones,
# so `availabilityZones` has no effect, and instances keep a public address for egress (no NAT).

variable "name" { type = string }
variable "region" { type = string }
# Network address of the VPC, e.g. 10.42.0.0, and its prefix length.
variable "v4_subnet" { type = string }
variable "v4_subnet_mask" {
  type    = number
  default = 20
}

resource "vultr_vpc" "this" {
  region         = var.region
  description    = var.name
  v4_subnet      = var.v4_subnet
  v4_subnet_mask = var.v4_subnet_mask
}

output "kind" { value = "network" }
output "network_id" { value = vultr_vpc.this.id }
output "region" { value = vultr_vpc.this.region }
output "cidr" { value = "${vultr_vpc.this.v4_subnet}/${vultr_vpc.this.v4_subnet_mask}" }
