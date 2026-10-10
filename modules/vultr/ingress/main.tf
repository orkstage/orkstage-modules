# Logical "ingress" on a Vultr load balancer. A Vultr load balancer sends every forwarding rule
# to the same attached instances and has one health check, so it serves one service: HTTP on
# port 80 (and HTTPS on 443 with automatic certificates when a domain is given) to the service
# port over the VPC. The service instances are attached by the adapter after the service is
# applied, which is why attached_instances is ignored here.

variable "name" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
# Resource id of the routed service (recorded so the service can find its load balancer).
variable "service" { type = string }
variable "port" { type = number }
variable "health_path" {
  type    = string
  default = "/"
}
# Domain (already pointing at the load balancer) for an automatic certificate; empty = HTTP only.
variable "auto_ssl_domain" {
  type    = string
  default = ""
}

locals {
  tls = var.auto_ssl_domain != ""
}

resource "vultr_load_balancer" "this" {
  region              = var.region
  label               = var.name
  balancing_algorithm = "roundrobin"
  vpc                 = var.vpc_id
  auto_ssl_domain     = local.tls ? var.auto_ssl_domain : null
  ssl_redirect        = local.tls

  forwarding_rules {
    frontend_protocol = "http"
    frontend_port     = 80
    backend_protocol  = "http"
    backend_port      = var.port
  }

  dynamic "forwarding_rules" {
    for_each = local.tls ? [1] : []
    content {
      frontend_protocol = "https"
      frontend_port     = 443
      backend_protocol  = "http"
      backend_port      = var.port
    }
  }

  health_check {
    protocol            = "http"
    path                = var.health_path
    port                = var.port
    check_interval      = 15
    response_timeout    = 5
    unhealthy_threshold = 3
    healthy_threshold   = 3
  }

  lifecycle {
    ignore_changes = [attached_instances]
  }
}

output "kind" { value = "ingress" }
output "id" { value = vultr_load_balancer.this.id }
output "lb_id" { value = vultr_load_balancer.this.id }
output "ipv4" { value = vultr_load_balancer.this.ipv4 }
output "service" { value = var.service }
output "port" { value = var.port }
output "url" { value = local.tls ? "https://${var.auto_ssl_domain}/" : "http://${vultr_load_balancer.this.ipv4}/" }
