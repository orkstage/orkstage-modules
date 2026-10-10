# Logical "ingress" on Azure Front Door Standard: one endpoint, one origin group and route per
# routed service. Services add themselves as origins of their group (see container-service), so
# routes exist before the apps behind them.

variable "name" { type = string }
variable "endpoint_name" { type = string } # globally unique, <= 46 chars
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "routes" {
  type = list(object({
    service     = string
    path_prefix = string
    health_path = string
  }))
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_cdn_frontdoor_profile" "this" {
  name                = var.name
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  name                     = var.endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "route" {
  for_each                 = { for r in var.routes : r.service => r }
  name                     = each.key
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this.id
  session_affinity_enabled = false

  load_balancing {}

  health_probe {
    protocol            = "Https"
    path                = each.value.health_path
    request_type        = "GET"
    interval_in_seconds = 60
  }
}

resource "azurerm_cdn_frontdoor_route" "route" {
  for_each                      = { for r in var.routes : r.service => r }
  name                          = each.key
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.route[each.key].id
  # The most specific pattern wins, so "/" can sit next to longer prefixes.
  patterns_to_match      = each.value.path_prefix == "/" ? ["/*"] : [trimsuffix(each.value.path_prefix, "/"), "${trimsuffix(each.value.path_prefix, "/")}/*"]
  supported_protocols    = ["Http", "Https"]
  https_redirect_enabled = true
  forwarding_protocol    = "HttpsOnly"
  link_to_default_domain = true
}

output "kind" { value = "ingress" }
output "resource_id" { value = azurerm_cdn_frontdoor_profile.this.id }
output "resource_group" { value = azurerm_resource_group.this.name }
output "url" { value = "https://${azurerm_cdn_frontdoor_endpoint.this.host_name}/" }
# JSON map service -> origin group id (outputs are flat strings for the control plane).
output "origin_groups" { value = jsonencode({ for k, g in azurerm_cdn_frontdoor_origin_group.route : k => g.id }) }
