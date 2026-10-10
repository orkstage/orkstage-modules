# Logical "network" on Magalu Cloud: a VPC, a subnet pool with one IPv4 subnet, and a security
# group that allows traffic between workloads inside the VPC. The subnet's availability zone is
# published so virtual machines land in the same zone.

variable "name" { type = string }
variable "cidr" { type = string } # subnet pool, e.g. 10.42.0.0/16

resource "mgc_network_vpcs" "this" {
  name        = var.name
  description = "Managed by OrkStage"
}

resource "mgc_network_subnetpools" "this" {
  name        = var.name
  description = "Managed by OrkStage"
  cidr        = var.cidr
}

resource "mgc_network_vpcs_subnets" "this" {
  name            = "${var.name}-main"
  description     = "Managed by OrkStage"
  vpc_id          = mgc_network_vpcs.this.id
  subnetpool_id   = mgc_network_subnetpools.this.id
  cidr_block      = cidrsubnet(var.cidr, 8, 0)
  ip_version      = "IPv4"
  dns_nameservers = ["8.8.8.8", "8.8.4.4"]
}

# Traffic between workloads inside the VPC only.
resource "mgc_network_security_groups" "internal" {
  name        = "${var.name}-internal"
  description = "Intra VPC traffic for ${var.name}"
}

resource "mgc_network_security_groups_rules" "internal" {
  for_each          = toset(["tcp", "udp", "icmp"])
  security_group_id = mgc_network_security_groups.internal.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value
  remote_ip_prefix  = var.cidr
  description       = "Intra VPC ${each.value}"
}

output "kind" { value = "network" }
output "network_id" { value = mgc_network_vpcs.this.id }
output "vpc_id" { value = mgc_network_vpcs.this.id }
output "subnet_id" { value = mgc_network_vpcs_subnets.this.id }
output "subnetpool_id" { value = mgc_network_subnetpools.this.id }
output "availability_zone" { value = mgc_network_vpcs_subnets.this.availability_zone }
output "cidr" { value = var.cidr }
output "internal_sg_id" { value = mgc_network_security_groups.internal.id }
