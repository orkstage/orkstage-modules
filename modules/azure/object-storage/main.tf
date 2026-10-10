# Logical "object-storage" on Azure Blob Storage: a storage account with one container. Shared
# keys are off; apps reach it with their managed identity (see container-service).

variable "account_name" { type = string } # globally unique, 3 to 24 lowercase letters and digits
variable "container_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tier" {
  type    = string
  default = "standard"
  validation {
    condition     = contains(["standard", "infrequent", "archive"], var.tier)
    error_message = "tier must be standard, infrequent or archive."
  }
}
variable "versioning" {
  type    = bool
  default = false
}
variable "public_access" {
  type    = bool
  default = false
}
variable "retention_days" {
  type    = number
  default = null
}
variable "production" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  expire  = var.retention_days != null && coalesce(var.retention_days, 0) > 0
  archive = var.tier == "archive"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "this" {
  name                            = var.account_name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = var.tier == "standard" ? "Hot" : "Cool"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = var.public_access
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  tags                            = var.tags

  blob_properties {
    versioning_enabled = var.versioning
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "this" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = var.public_access ? "blob" : "private"
}

# Archive is a blob tier, not an account tier: new blobs move there right away.
resource "azurerm_storage_management_policy" "this" {
  count              = local.expire || local.archive ? 1 : 0
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "orkstage-lifecycle"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["${var.container_name}/"]
    }
    actions {
      base_blob {
        tier_to_archive_after_days_since_modification_greater_than = local.archive ? 0 : null
        delete_after_days_since_modification_greater_than          = local.expire ? var.retention_days : null
      }
      dynamic "version" {
        for_each = local.expire && var.versioning ? [1] : []
        content {
          delete_after_days_since_creation = var.retention_days
        }
      }
    }
  }
}

# Deletion protection in production.
resource "azurerm_management_lock" "this" {
  count      = var.production ? 1 : 0
  name       = "orkstage-production"
  scope      = azurerm_storage_account.this.id
  lock_level = "CanNotDelete"
  notes      = "Production storage managed by OrkStage."
}

output "kind" { value = "object-storage" }
output "resource_id" { value = azurerm_storage_account.this.id }
output "resource_group" { value = azurerm_resource_group.this.name }
output "storage_account" { value = azurerm_storage_account.this.name }
output "storage_account_id" { value = azurerm_storage_account.this.id }
output "bucket" { value = azurerm_storage_container.this.name }
output "endpoint" { value = azurerm_storage_account.this.primary_blob_endpoint }
output "region" { value = azurerm_storage_account.this.location }
