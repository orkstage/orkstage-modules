# Logical "network" on CoreWeave: a zonal VPC with the named prefixes a CKS cluster needs for
# pods, services and internal load balancers. Internet egress is built into the VPC.

variable "name" { type = string } # at most 30 characters
variable "zone" { type = string }
variable "pod_cidr" { type = string }
variable "service_cidr" { type = string }
variable "internal_lb_cidr" { type = string }

locals {
  pod_cidr_name         = "pod cidr"
  service_cidr_name     = "service cidr"
  internal_lb_cidr_name = "internal lb cidr"
}

resource "coreweave_networking_vpc" "this" {
  name = var.name
  zone = var.zone

  vpc_prefixes = [
    { name = local.pod_cidr_name, value = var.pod_cidr },
    { name = local.service_cidr_name, value = var.service_cidr },
    { name = local.internal_lb_cidr_name, value = var.internal_lb_cidr },
  ]

  egress  = { disable_public_access = false }
  ingress = { disable_public_services = false }
}

output "kind" { value = "network" }
output "network_id" { value = coreweave_networking_vpc.this.id }
output "vpc_name" { value = coreweave_networking_vpc.this.name }
output "zone" { value = var.zone }
output "pod_cidr_name" { value = local.pod_cidr_name }
output "service_cidr_name" { value = local.service_cidr_name }
output "internal_lb_cidr_name" { value = local.internal_lb_cidr_name }
