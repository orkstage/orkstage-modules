# Logical "cache.redis" on OCI Cache: a non sharded Valkey cluster (one primary and up to four
# replicas) in a private subnet. OCI Cache always encrypts traffic in transit (TLS on 6379).

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "node_memory_gbs" { type = number }
# Primary plus replicas, 1 to 5.
variable "node_count" {
  type = number
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5."
  }
}
variable "software_version" {
  type    = string
  default = "VALKEY_7_2"
}
variable "vcn_id" { type = string }
variable "vcn_cidr" { type = string }
variable "subnet_id" { type = string }
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

resource "oci_core_network_security_group" "cache" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-cache"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "cache" {
  network_security_group_id = oci_core_network_security_group.cache.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 6379
      max = 6379
    }
  }
}

resource "oci_redis_redis_cluster" "this" {
  compartment_id     = var.compartment_id
  display_name       = var.name
  cluster_mode       = "NONSHARDED"
  node_count         = var.node_count
  node_memory_in_gbs = var.node_memory_gbs
  software_version   = var.software_version
  subnet_id          = var.subnet_id
  nsg_ids            = [oci_core_network_security_group.cache.id]
  freeform_tags      = var.freeform_tags
}

output "kind" { value = "cache.redis" }
output "id" { value = oci_redis_redis_cluster.this.id }
output "host" { value = oci_redis_redis_cluster.this.primary_fqdn }
output "port" { value = 6379 }
output "tls" { value = true }
