# Logical "compute.container-service" on Azure Container Apps. The app runs in the environment
# of its network (or in an environment of its own when there is no network), with a user
# assigned identity that reads exactly the Key Vaults and storage accounts it depends on.

variable "name" { type = string } # <= 32 chars
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "image" { type = string }
variable "cpu" { type = number }    # vCPU, 0.25 steps
variable "memory" { type = string } # e.g. "0.5Gi", twice the vCPU
variable "replicas" { type = number }
variable "port" {
  type    = number
  default = null
}
variable "public" {
  type    = bool
  default = false
}
variable "health_path" {
  type    = string
  default = ""
}
# Plain configuration (hosts, ports, URLs). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
# ENV_NAME => Key Vault secret (versionless id) and its vault; resolved by Container Apps at
# start, the values never pass through OpenTofu.
variable "secrets" {
  type = map(object({
    secret_id = string
    vault_id  = string
  }))
  default = {}
}
# NAME => value of credentials owned by another provider, copied by OrkStage at deploy time
# through TF_VAR_external_secrets (never written to files).
variable "external_secrets" {
  type      = map(string)
  default   = {}
  sensitive = true
}
# Storage accounts the app may read and write with its identity.
variable "storage_account_ids" {
  type    = list(string)
  default = []
}
# Shared environment from the network. Empty: the module creates one without a network.
variable "environment_id" {
  type    = string
  default = ""
}
variable "log_workspace_id" {
  type    = string
  default = ""
}
# Front Door origin group to join (ingress "front-door"). Empty: none.
variable "origin_group_id" {
  type    = string
  default = ""
}
# Scale on average CPU. null = fixed `replicas`.
variable "autoscaling" {
  type = object({
    min_replicas       = number
    max_replicas       = number
    target_cpu_percent = number
  })
  default = null
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  own_env = var.environment_id == ""
  scaled  = var.autoscaling != null
  # The CPU scaler cannot wake an app from zero, so a scaled app keeps at least one replica.
  min_replicas   = local.scaled ? max(1, var.autoscaling.min_replicas) : var.replicas
  max_replicas   = local.scaled ? max(local.min_replicas, var.autoscaling.max_replicas) : max(1, var.replicas)
  vault_ids      = toset([for s in values(var.secrets) : s.vault_id])
  secret_names   = { for k, s in var.secrets : k => lower(replace(k, "_", "-")) }
  external_keys  = nonsensitive(keys(var.external_secrets))
  external_names = { for k in local.external_keys : k => "ext-${lower(replace(k, "_", "-"))}" }
  grants         = length(var.secrets) + length(var.storage_account_ids)
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "own" {
  count               = local.own_env ? 1 : 0
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_container_app_environment" "own" {
  count                      = local.own_env ? 1 : 0
  name                       = var.name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.own[0].id
  logs_destination           = "log-analytics"
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
  tags = var.tags
}

resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.name}-id"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "secrets" {
  for_each             = local.vault_ids
  scope                = each.value
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "storage" {
  for_each             = toset(var.storage_account_ids)
  scope                = each.value
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
  principal_type       = "ServicePrincipal"
}

# Role assignments take a while to reach Key Vault; without the wait the first revision fails
# to read its secrets.
resource "time_sleep" "rbac" {
  count           = local.grants > 0 ? 1 : 0
  create_duration = "60s"
  triggers = {
    grants = join(",", concat(sort(tolist(local.vault_ids)), sort(var.storage_account_ids)))
  }
  depends_on = [azurerm_role_assignment.secrets, azurerm_role_assignment.storage]
}

resource "azurerm_container_app" "this" {
  name                         = var.name
  container_app_environment_id = local.own_env ? azurerm_container_app_environment.own[0].id : var.environment_id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  dynamic "secret" {
    for_each = var.secrets
    content {
      name                = local.secret_names[secret.key]
      identity            = azurerm_user_assigned_identity.app.id
      key_vault_secret_id = secret.value.secret_id
    }
  }

  # Credentials of resources on other providers: stored as Container Apps secrets.
  dynamic "secret" {
    for_each = toset(local.external_keys)
    content {
      name  = local.external_names[secret.key]
      value = var.external_secrets[secret.key]
    }
  }

  dynamic "ingress" {
    for_each = var.port == null ? [] : [1]
    content {
      external_enabled           = var.public
      target_port                = var.port
      transport                  = "auto"
      allow_insecure_connections = false
      traffic_weight {
        latest_revision = true
        percentage      = 100
      }
    }
  }

  template {
    min_replicas = local.min_replicas
    max_replicas = local.max_replicas

    container {
      name   = "app"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      # Lets Azure SDKs in the app pick the user assigned identity (storage access).
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }
      dynamic "env" {
        for_each = var.environment
        content {
          name  = env.key
          value = env.value
        }
      }
      dynamic "env" {
        for_each = var.secrets
        content {
          name        = env.key
          secret_name = local.secret_names[env.key]
        }
      }
      dynamic "env" {
        for_each = toset(local.external_keys)
        content {
          name        = env.key
          secret_name = local.external_names[env.key]
        }
      }

      dynamic "liveness_probe" {
        for_each = var.port != null && var.health_path != "" ? [1] : []
        content {
          transport = "HTTP"
          port      = var.port
          path      = var.health_path
        }
      }
      dynamic "readiness_probe" {
        for_each = var.port != null && var.health_path != "" ? [1] : []
        content {
          transport = "HTTP"
          port      = var.port
          path      = var.health_path
        }
      }
    }

    dynamic "custom_scale_rule" {
      for_each = local.scaled ? [1] : []
      content {
        name             = "cpu"
        custom_rule_type = "cpu"
        metadata = {
          type  = "Utilization"
          value = tostring(var.autoscaling.target_cpu_percent)
        }
      }
    }
  }

  depends_on = [time_sleep.rbac]
}

# Registers the app behind the Front Door route that names it.
resource "azurerm_cdn_frontdoor_origin" "this" {
  count                          = var.origin_group_id != "" && var.port != null && var.public ? 1 : 0
  name                           = "app"
  cdn_frontdoor_origin_group_id  = var.origin_group_id
  host_name                      = azurerm_container_app.this.ingress[0].fqdn
  origin_host_header             = azurerm_container_app.this.ingress[0].fqdn
  certificate_name_check_enabled = true
  http_port                      = 80
  https_port                     = 443
}

locals {
  fqdn = var.port == null ? "" : azurerm_container_app.this.ingress[0].fqdn
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = azurerm_container_app.this.id }
output "name" { value = azurerm_container_app.this.name }
output "resource_group" { value = azurerm_resource_group.this.name }
output "url" { value = local.fqdn == "" ? "" : "https://${local.fqdn}" }
output "image" { value = var.image }
output "identity_client_id" { value = azurerm_user_assigned_identity.app.client_id }
output "log_workspace_id" { value = local.own_env ? azurerm_log_analytics_workspace.own[0].workspace_id : var.log_workspace_id }
output "autoscaling" { value = local.scaled ? "${local.min_replicas}-${local.max_replicas} @ ${var.autoscaling.target_cpu_percent}% CPU" : "off" }
