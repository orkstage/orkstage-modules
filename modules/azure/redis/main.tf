# Logical "cache.redis" on Azure Managed Redis. With a network the cache is reachable only
# through a private endpoint; the access key is kept in a Key Vault secret the module creates.

variable "name" { type = string } # globally unique, <= 60 chars
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "vault_name" { type = string } # globally unique, <= 24 chars
variable "sku_name" { type = string }
variable "high_availability" {
  type    = bool
  default = false
}
variable "production" {
  type    = bool
  default = false
}
# Private endpoint subnet and the network's privatelink.redis.azure.net zone. Empty: public.
variable "private_subnet_id" {
  type    = string
  default = ""
}
variable "dns_zone_id" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  private = var.private_subnet_id != ""
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_managed_redis" "this" {
  name                      = var.name
  resource_group_name       = azurerm_resource_group.this.name
  location                  = azurerm_resource_group.this.location
  sku_name                  = var.sku_name
  high_availability_enabled = var.high_availability
  public_network_access     = local.private ? "Disabled" : "Enabled"
  tags                      = var.tags

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    # A single endpoint that plain (non cluster aware) Redis clients can use.
    clustering_policy = "EnterpriseCluster"
    eviction_policy   = "VolatileLRU"
  }
}

resource "azurerm_private_endpoint" "this" {
  count               = local.private ? 1 : 0
  name                = "${var.name}-pe"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = var.private_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name}-redis"
    private_connection_resource_id = azurerm_managed_redis.this.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [var.dns_zone_id]
  }
}

resource "azurerm_key_vault" "this" {
  name                       = var.vault_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.production
  soft_delete_retention_days = var.production ? 90 : 7
  tags                       = var.tags
}

resource "azurerm_role_assignment" "deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.deployer]
}

locals {
  host = azurerm_managed_redis.this.hostname
  port = azurerm_managed_redis.this.default_database[0].port
}

# The access key is already in state as a computed attribute of the cache, so the secret can
# take it as a regular value.
resource "azurerm_key_vault_secret" "credentials" {
  name         = "credentials"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value = jsonencode({
    host     = local.host
    port     = tostring(local.port)
    password = azurerm_managed_redis.this.default_database[0].primary_access_key
    url      = "rediss://:${azurerm_managed_redis.this.default_database[0].primary_access_key}@${local.host}:${local.port}"
  })
  depends_on = [time_sleep.rbac]
}

output "kind" { value = "cache.redis" }
output "resource_id" { value = azurerm_managed_redis.this.id }
output "resource_group" { value = azurerm_resource_group.this.name }
output "host" { value = local.host }
output "port" { value = local.port }
output "tls" { value = true }
output "secret_ref" { value = azurerm_key_vault_secret.credentials.versionless_id }
output "key_vault_id" { value = azurerm_key_vault.this.id }
