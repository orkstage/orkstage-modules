# Logical "compute.container-service" on OCI Container Instances. Each replica is one container
# instance (CI.Standard.E4.Flex), spread across availability domains. When an ingress routes to
# this service, every instance registers its private IP as a backend of the service's backend set.

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "image" { type = string }
variable "ocpus" { type = number }
variable "memory_gbs" { type = number }
variable "replicas" { type = number }
variable "port" {
  type    = number
  default = null
}
variable "vcn_id" { type = string }
variable "vcn_cidr" { type = string }
variable "subnet_id" { type = string }
variable "assign_public_ip" {
  type    = bool
  default = false
}
# Open the port to the internet (only with a public IP and no ingress in front).
variable "public" {
  type    = bool
  default = false
}
# Plain configuration (hosts, ports, URLs, secret OCIDs). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
variable "health_path" {
  type    = string
  default = ""
}
variable "shape" {
  type    = string
  default = "CI.Standard.E4.Flex"
}
variable "load_balancer_id" {
  type    = string
  default = ""
}
variable "backend_set_name" {
  type    = string
  default = ""
}
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

data "oci_identity_availability_domains" "all" {
  compartment_id = var.compartment_id
}

locals {
  ads         = data.oci_identity_availability_domains.all.availability_domains[*].name
  behind_lb   = var.load_balancer_id != "" && var.backend_set_name != "" && var.port != null
  open_public = var.public && var.assign_public_ip && var.port != null && !local.behind_lb
  health      = var.health_path != "" && var.port != null
}

resource "oci_core_network_security_group" "service" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-svc"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "egress" {
  network_security_group_id = oci_core_network_security_group.service.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group_security_rule" "vcn" {
  count                     = var.port == null ? 0 : 1
  network_security_group_id = oci_core_network_security_group.service.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = var.port
      max = var.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internet" {
  count                     = local.open_public ? 1 : 0
  network_security_group_id = oci_core_network_security_group.service.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = var.port
      max = var.port
    }
  }
}

resource "oci_container_instances_container_instance" "this" {
  count                    = var.replicas
  compartment_id           = var.compartment_id
  availability_domain      = local.ads[count.index % length(local.ads)]
  display_name             = "${var.name}-${count.index}"
  shape                    = var.shape
  container_restart_policy = "ALWAYS"
  freeform_tags            = var.freeform_tags

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  containers {
    display_name          = var.name
    image_url             = var.image
    environment_variables = var.environment
    freeform_tags         = var.freeform_tags

    dynamic "health_checks" {
      for_each = local.health ? [1] : []
      content {
        health_check_type        = "HTTP"
        path                     = var.health_path
        port                     = var.port
        initial_delay_in_seconds = 30
        interval_in_seconds      = 15
        failure_threshold        = 3
        failure_action           = "KILL"
      }
    }
  }

  vnics {
    subnet_id             = var.subnet_id
    is_public_ip_assigned = var.assign_public_ip
    nsg_ids               = [oci_core_network_security_group.service.id]
    display_name          = "${var.name}-${count.index}"
  }

  # Container instances are immutable: a new image or setting replaces them. Start the new
  # instances before stopping the old ones.
  lifecycle {
    create_before_destroy = true
  }
}

resource "oci_load_balancer_backend" "this" {
  count            = local.behind_lb ? var.replicas : 0
  load_balancer_id = var.load_balancer_id
  backendset_name  = var.backend_set_name
  ip_address       = oci_container_instances_container_instance.this[count.index].vnics[0].private_ip
  port             = var.port
}

data "oci_core_vnic" "first" {
  count   = local.open_public && var.replicas > 0 ? 1 : 0
  vnic_id = oci_container_instances_container_instance.this[0].vnics[0].vnic_id
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = var.replicas > 0 ? oci_container_instances_container_instance.this[0].id : "" }
output "instance_ids" { value = join(",", oci_container_instances_container_instance.this[*].id) }
output "private_ips" { value = join(",", [for ci in oci_container_instances_container_instance.this : ci.vnics[0].private_ip]) }
output "image" { value = var.image }
output "replicas" { value = var.replicas }
output "url" { value = length(data.oci_core_vnic.first) > 0 ? "http://${data.oci_core_vnic.first[0].public_ip_address}:${var.port}/" : "" }
