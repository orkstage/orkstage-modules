# Logical "network" on OCI: a VCN with one public and one private regional subnet (OCI subnets
# span every availability domain of the region), an internet gateway, a service gateway to the
# Oracle Services Network, and an optional NAT gateway for private egress.

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "cidr" { type = string }
# Letters and digits, starting with a letter, at most 15 characters.
variable "dns_label" { type = string }
variable "nat_gateway" {
  type    = bool
  default = false
}
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

locals {
  public_cidr  = cidrsubnet(var.cidr, 4, 0)
  private_cidr = cidrsubnet(var.cidr, 4, 8)
  osn          = data.oci_core_services.all.services[0]
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.cidr]
  display_name   = var.name
  dns_label      = var.dns_label
  freeform_tags  = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

resource "oci_core_service_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sgw"
  freeform_tags  = var.freeform_tags
  services {
    service_id = local.osn.id
  }
}

resource "oci_core_nat_gateway" "this" {
  count          = var.nat_gateway ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nat"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-public"
  freeform_tags  = var.freeform_tags
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-private"
  freeform_tags  = var.freeform_tags
  route_rules {
    destination       = local.osn.cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this.id
  }
  dynamic "route_rules" {
    for_each = var.nat_gateway ? [1] : []
    content {
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_nat_gateway.this[0].id
    }
  }
}

# Public subnet: HTTP and HTTPS from the internet (load balancers), anything from inside the VCN.
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-public"
  freeform_tags  = var.freeform_tags
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  ingress_security_rules {
    source   = var.cidr
    protocol = "all"
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 80
      max = 80
    }
  }
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6"
    tcp_options {
      min = 443
      max = 443
    }
  }
}

# Private subnet: traffic from inside the VCN only.
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-private"
  freeform_tags  = var.freeform_tags
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  ingress_security_rules {
    source   = var.cidr
    protocol = "all"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.this.id
  cidr_block        = local.public_cidr
  display_name      = "${var.name}-public"
  dns_label         = "pub"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
  freeform_tags     = var.freeform_tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.private_cidr
  display_name               = "${var.name}-private"
  dns_label                  = "priv"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  freeform_tags              = var.freeform_tags
}

output "kind" { value = "network" }
output "network_id" { value = oci_core_vcn.this.id }
output "vcn_id" { value = oci_core_vcn.this.id }
output "cidr" { value = var.cidr }
output "public_subnet_id" { value = oci_core_subnet.public.id }
output "private_subnet_id" { value = oci_core_subnet.private.id }
output "public_subnet_ids" { value = oci_core_subnet.public.id }
output "private_subnet_ids" { value = oci_core_subnet.private.id }
# Without NAT, private subnets reach only Oracle services; workloads that pull public images
# must run in the public subnet.
output "private_egress" { value = var.nat_gateway }
# Fixed public address of the NAT gateway, for allowlists on other providers.
output "egress_ips" { value = join(",", oci_core_nat_gateway.this[*].nat_ip) }
