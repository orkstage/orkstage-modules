# Logical "network": a virtual network in its own resource group, with a delegated subnet for
# Container Apps, a delegated subnet for PostgreSQL flexible servers and a subnet for private
# endpoints. It also hosts the Container Apps environment every container service in this
# network shares: Azure gives each environment a subnet of its own, so one environment per
# service would limit a network to a single service.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "cidr" { type = string }
variable "environment_name" { type = string } # <= 32 chars
variable "zone_redundant" {
  type    = bool
  default = false
}
variable "nat_gateway" {
  type    = bool
  default = false
}
variable "log_retention_days" {
  type    = number
  default = 30
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

resource "azurerm_virtual_network" "this" {
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.cidr]
  tags                = var.tags
}

# /23: the minimum Container Apps accepts for an environment with workload profiles is /27,
# a larger range leaves room for replicas and upgrades.
resource "azurerm_subnet" "apps" {
  name                 = "apps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.cidr, 7, 0)]
  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Several flexible servers can share one delegated subnet.
resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.cidr, 8, 2)]
  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private" {
  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.cidr, 8, 3)]
}

resource "azurerm_public_ip" "nat" {
  count               = var.nat_gateway ? 1 : 0
  name                = "${var.name}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count               = var.nat_gateway ? 1 : 0
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count                = var.nat_gateway ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "apps" {
  count          = var.nat_gateway ? 1 : 0
  subnet_id      = azurerm_subnet.apps.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = var.environment_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  logs_destination           = "log-analytics"
  infrastructure_subnet_id   = azurerm_subnet.apps.id
  # A fixed name keeps plans stable; Azure creates and deletes this group with the environment.
  infrastructure_resource_group_name = "${var.resource_group_name}-infra"
  internal_load_balancer_enabled     = false
  zone_redundancy_enabled            = var.zone_redundant
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  tags       = var.tags
  depends_on = [azurerm_subnet_nat_gateway_association.apps]
}

# Shared by every Azure Managed Redis private endpoint in this network: a virtual network can
# link only one zone per name.
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                = "${var.name}-redis"
  private_dns_zone_id = azurerm_private_dns_zone.redis.id
  virtual_network_id  = azurerm_virtual_network.this.id
  tags                = var.tags
}

output "kind" { value = "network" }
output "network_id" { value = azurerm_virtual_network.this.id }
output "resource_group" { value = azurerm_resource_group.this.name }
output "vnet_name" { value = azurerm_virtual_network.this.name }
output "cidr" { value = var.cidr }
output "apps_subnet_id" { value = azurerm_subnet.apps.id }
output "postgres_subnet_id" { value = azurerm_subnet.postgres.id }
output "private_subnet_id" { value = azurerm_subnet.private.id }
output "container_app_environment_id" { value = azurerm_container_app_environment.this.id }
output "default_domain" { value = azurerm_container_app_environment.this.default_domain }
output "static_ip" { value = azurerm_container_app_environment.this.static_ip_address }
# Workspace (customer) id used by the Log Analytics query API.
output "log_workspace_id" { value = azurerm_log_analytics_workspace.this.workspace_id }
output "redis_dns_zone_id" { value = azurerm_private_dns_zone.redis.id }
output "private_egress" { value = var.nat_gateway }
# Fixed public address of the apps subnet's outbound traffic, for allowlists on other providers.
output "egress_ips" { value = join(",", azurerm_public_ip.nat[*].ip_address) }
