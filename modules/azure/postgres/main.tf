# Logical "database.postgresql" on Azure Database for PostgreSQL flexible server. The admin
# password is generated ephemerally and written only through write only attributes (server and
# Key Vault secret): it never appears in OpenTofu state.

variable "name" { type = string } # globally unique, <= 63 chars
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "vault_name" { type = string } # globally unique, <= 24 chars
variable "engine_version" { type = string }
variable "sku_name" { type = string }
variable "storage_mb" { type = number }
variable "high_availability" {
  type    = string
  default = "none"
  validation {
    condition     = contains(["none", "SameZone", "ZoneRedundant"], var.high_availability)
    error_message = "high_availability must be none, SameZone or ZoneRedundant."
  }
}
variable "backup_retention_days" {
  type    = number
  default = 7
}
variable "production" {
  type    = bool
  default = false
}
# Private access: delegated subnet of the network and the network itself (for the DNS link).
# Empty: public endpoint reachable from Azure services only.
variable "delegated_subnet_id" {
  type    = string
  default = ""
}
variable "vnet_id" {
  type    = string
  default = ""
}
variable "username" {
  type    = string
  default = "orkadmin"
}
variable "database" {
  type    = string
  default = "app"
}
# Bump to rotate the admin password.
variable "password_version" {
  type    = number
  default = 1
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  private = var.delegated_subnet_id != ""
}

data "azurerm_client_config" "current" {}

ephemeral "random_password" "admin" {
  length  = 32
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_private_dns_zone" "this" {
  count               = local.private ? 1 : 0
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count               = local.private ? 1 : 0
  name                = "${var.name}-link"
  private_dns_zone_id = azurerm_private_dns_zone.this[0].id
  virtual_network_id  = var.vnet_id
  tags                = var.tags
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

# The deploying principal writes the secret; the control plane reads it back for readSecret.
resource "azurerm_role_assignment" "deployer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.deployer]
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                              = var.name
  resource_group_name               = azurerm_resource_group.this.name
  location                          = azurerm_resource_group.this.location
  version                           = var.engine_version
  sku_name                          = var.sku_name
  storage_mb                        = var.storage_mb
  auto_grow_enabled                 = true
  administrator_login               = var.username
  administrator_password_wo         = ephemeral.random_password.admin.result
  administrator_password_wo_version = var.password_version
  backup_retention_days             = var.backup_retention_days
  delegated_subnet_id               = local.private ? var.delegated_subnet_id : null
  private_dns_zone_id               = local.private ? azurerm_private_dns_zone.this[0].id : null
  public_network_access_enabled     = !local.private
  tags                              = var.tags

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  dynamic "high_availability" {
    for_each = var.high_availability == "none" ? [] : [1]
    content {
      mode = var.high_availability
    }
  }

  # Azure picks the zones and may swap them on failover.
  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}

# Without a network the server is public, open to Azure services only (0.0.0.0 means that).
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  count            = local.private ? 0 : 1
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_key_vault_secret" "credentials" {
  name         = "credentials"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value_wo = jsonencode({
    username = var.username
    password = ephemeral.random_password.admin.result
    host     = azurerm_postgresql_flexible_server.this.fqdn
    port     = "5432"
    database = var.database
    url      = "postgresql://${var.username}:${ephemeral.random_password.admin.result}@${azurerm_postgresql_flexible_server.this.fqdn}:5432/${var.database}?sslmode=require"
  })
  value_wo_version = var.password_version
  depends_on       = [time_sleep.rbac]
}

# Deletion protection in production: OpenTofu cannot destroy the server until the lock is removed.
resource "azurerm_management_lock" "this" {
  count      = var.production ? 1 : 0
  name       = "orkstage-production"
  scope      = azurerm_postgresql_flexible_server.this.id
  lock_level = "CanNotDelete"
  notes      = "Production database managed by OrkStage."
}

output "kind" { value = "database.postgresql" }
output "resource_id" { value = azurerm_postgresql_flexible_server.this.id }
output "resource_group" { value = azurerm_resource_group.this.name }
output "host" { value = azurerm_postgresql_flexible_server.this.fqdn }
output "port" { value = 5432 }
output "database" { value = var.database }
output "username" { value = var.username }
# A reference, not a value: services receive it as a Key Vault backed secret.
output "secret_ref" { value = azurerm_key_vault_secret.credentials.versionless_id }
output "key_vault_id" { value = azurerm_key_vault.this.id }
