# Logical "ingress" on OCI: a public flexible load balancer with one backend set per routed
# service and an HTTP listener that routes by longest path prefix. Services register their
# container instances as backends of their own backend set (see container-service).

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "subnet_id" { type = string }
variable "routes" {
  type = list(object({
    service     = string
    path_prefix = string
    health_path = string
  }))
}
variable "min_bandwidth_mbps" {
  type    = number
  default = 10
}
variable "max_bandwidth_mbps" {
  type    = number
  default = 100
}
variable "production" {
  type    = bool
  default = false
}
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

locals {
  catch_all = [for r in var.routes : r.service if r.path_prefix == "/"]
  default   = length(local.catch_all) > 0 ? local.catch_all[0] : var.routes[0].service
}

resource "oci_load_balancer_load_balancer" "this" {
  compartment_id               = var.compartment_id
  display_name                 = var.name
  shape                        = "flexible"
  subnet_ids                   = [var.subnet_id]
  is_private                   = false
  is_delete_protection_enabled = var.production
  freeform_tags                = var.freeform_tags
  shape_details {
    minimum_bandwidth_in_mbps = var.min_bandwidth_mbps
    maximum_bandwidth_in_mbps = var.max_bandwidth_mbps
  }
}

resource "oci_load_balancer_backend_set" "route" {
  for_each         = { for r in var.routes : r.service => r }
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = each.key
  policy           = "ROUND_ROBIN"
  health_checker {
    protocol          = "HTTP"
    url_path          = each.value.health_path
    return_code       = 200
    interval_ms       = 15000
    timeout_in_millis = 5000
    retries           = 3
  }
}

resource "oci_load_balancer_path_route_set" "this" {
  load_balancer_id = oci_load_balancer_load_balancer.this.id
  name             = "routes"
  dynamic "path_routes" {
    for_each = var.routes
    content {
      path             = path_routes.value.path_prefix
      backend_set_name = oci_load_balancer_backend_set.route[path_routes.value.service].name
      path_match_type {
        match_type = "FORCE_LONGEST_PREFIX_MATCH"
      }
    }
  }
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.this.id
  name                     = "http"
  port                     = 80
  protocol                 = "HTTP"
  default_backend_set_name = oci_load_balancer_backend_set.route[local.default].name
  path_route_set_name      = oci_load_balancer_path_route_set.this.name
}

locals {
  public_ip = [for ip in oci_load_balancer_load_balancer.this.ip_address_details : ip.ip_address if ip.is_public]
}

output "kind" { value = "ingress" }
output "id" { value = oci_load_balancer_load_balancer.this.id }
output "load_balancer_id" { value = oci_load_balancer_load_balancer.this.id }
output "ip_address" { value = length(local.public_ip) > 0 ? local.public_ip[0] : "" }
# JSON map service -> backend set name (outputs are flat strings for the control plane).
output "backend_sets" { value = jsonencode({ for k, b in oci_load_balancer_backend_set.route : k => b.name }) }
output "url" { value = length(local.public_ip) > 0 ? "http://${local.public_ip[0]}/" : "" }
