# Logical "dns": a platform subdomain aliased to the ingress, with an ACM certificate (DNS
# validated) and an HTTPS listener on the load balancer when TLS is requested.

variable "zone_name" { type = string } # platform zone, e.g. apps.example.com
variable "create_zone" {
  type    = bool
  default = false
}
variable "record_label" { type = string } # e.g. production-acme
variable "lb_dns_name" { type = string }
variable "lb_zone_id" { type = string }
variable "lb_arn" { type = string }
variable "default_target_group_arn" {
  type    = string
  default = ""
}
variable "tls" {
  type    = bool
  default = true
}
# Custom hostnames whose ownership OrkStage verified. Their certificate is validated with records
# the domain owner creates, so applying never waits for it.
variable "custom_domains" {
  type    = list(string)
  default = []
}
# Security policy of the HTTPS listener. The platform policy `minTlsVersion: 1.3` selects the
# TLS 1.3 only policy.
variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}
# True once OrkStage saw the custom certificate issued: only then can the listener use it.
variable "attach_custom_certificate" {
  type    = bool
  default = false
}

resource "aws_route53_zone" "created" {
  count = var.create_zone ? 1 : 0
  name  = var.zone_name
}

data "aws_route53_zone" "existing" {
  count = var.create_zone ? 0 : 1
  name  = var.zone_name
}

locals {
  zone_id = var.create_zone ? aws_route53_zone.created[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  fqdn    = "${var.record_label}.${var.zone_name}"
}

resource "aws_route53_record" "app" {
  zone_id = local.zone_id
  name    = local.fqdn
  type    = "A"
  alias {
    name                   = var.lb_dns_name
    zone_id                = var.lb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_acm_certificate" "this" {
  count             = var.tls ? 1 : 0
  domain_name       = local.fqdn
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "validation" {
  for_each        = var.tls ? { for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => o } : {}
  zone_id         = local.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count                   = var.tls ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count             = var.tls && var.default_target_group_arn != "" ? 1 : 0
  load_balancer_arn = var.lb_arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = var.default_target_group_arn
  }
}

resource "aws_acm_certificate" "custom" {
  count                     = length(var.custom_domains) > 0 ? 1 : 0
  domain_name               = var.custom_domains[0]
  subject_alternative_names = slice(var.custom_domains, 1, length(var.custom_domains))
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_lb_listener_certificate" "custom" {
  count           = length(var.custom_domains) > 0 && var.attach_custom_certificate && length(aws_lb_listener.https) > 0 ? 1 : 0
  listener_arn    = aws_lb_listener.https[0].arn
  certificate_arn = aws_acm_certificate.custom[0].arn
}

output "kind" { value = "dns" }
output "fqdn" { value = local.fqdn }
output "zone_id" { value = local.zone_id }
output "tls" { value = var.tls ? "issued" : "disabled" }
output "certificate_arn" { value = var.tls ? aws_acm_certificate.this[0].arn : "" }
output "custom_domains" { value = join(",", var.custom_domains) }
output "custom_certificate_arn" { value = length(var.custom_domains) > 0 ? aws_acm_certificate.custom[0].arn : "" }
output "custom_certificate_attached" { value = length(aws_lb_listener_certificate.custom) > 0 ? "true" : "false" }
