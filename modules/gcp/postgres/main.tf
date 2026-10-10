# Logical "database.postgresql" on Cloud SQL (Enterprise edition). With a network the instance
# has only a private IP from the network's private services access range. The application
# password is generated here, kept in state and in a Secret Manager secret; outputs carry the
# secret's resource name, never the value.

variable "name" { type = string }
variable "region" { type = string }
variable "database_version" { type = string } # e.g. POSTGRES_17
variable "tier" { type = string }             # e.g. db-g1-small, db-custom-2-7680
variable "disk_gib" { type = number }
variable "high_availability" {
  type    = bool
  default = false
}
variable "backup_enabled" {
  type    = bool
  default = true
}
variable "backup_retention_days" {
  type    = number
  default = 7
}
variable "public_access" {
  type    = bool
  default = false
}
variable "network_id" {
  type    = string
  default = ""
}
variable "production" {
  type    = bool
  default = false
}
variable "username" {
  type    = string
  default = "app"
}
variable "database" {
  type    = string
  default = "app"
}
# Bump to rotate the application password.
variable "password_version" {
  type    = number
  default = 1
}

locals {
  private = var.network_id != ""
  # Regional (HA) instances need backups and point in time recovery.
  backups = var.backup_enabled || var.high_availability
  host    = local.private ? google_sql_database_instance.this.private_ip_address : google_sql_database_instance.this.public_ip_address
}

# Cloud SQL keeps a deleted instance name reserved for about a week; a suffix lets a destroyed
# resource be created again right away.
resource "random_id" "suffix" {
  byte_length = 2
}

resource "random_password" "app" {
  length  = 32
  special = false
  keepers = { version = var.password_version }
}

resource "google_sql_database_instance" "this" {
  name                = "${var.name}-${random_id.suffix.hex}"
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.production

  settings {
    tier                        = var.tier
    edition                     = "ENTERPRISE"
    availability_type           = var.high_availability ? "REGIONAL" : "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = var.disk_gib
    disk_autoresize             = true
    deletion_protection_enabled = var.production

    ip_configuration {
      ipv4_enabled                                  = var.public_access || !local.private
      private_network                               = local.private ? var.network_id : null
      enable_private_path_for_google_cloud_services = local.private
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled                        = local.backups
      point_in_time_recovery_enabled = local.backups
      transaction_log_retention_days = local.backups ? min(7, var.backup_retention_days) : null
      backup_retention_settings {
        retained_backups = max(1, var.backup_retention_days)
        retention_unit   = "COUNT"
      }
    }
  }
}

resource "google_sql_database" "this" {
  name     = var.database
  instance = google_sql_database_instance.this.name
  # Dropping the instance removes its databases; deleting first fails while sessions are open.
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "app" {
  name     = var.username
  instance = google_sql_database_instance.this.name
  password = random_password.app.result
  # Objects owned by the user block DROP ROLE; the instance deletion removes the user anyway.
  deletion_policy = "ABANDON"
}

resource "google_secret_manager_secret" "credentials" {
  secret_id = "${var.name}-credentials"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "credentials" {
  secret = google_secret_manager_secret.credentials.id
  secret_data = jsonencode({
    username = var.username
    password = random_password.app.result
    host     = local.host
    port     = 5432
    database = var.database
    url      = "postgresql://${var.username}:${random_password.app.result}@${local.host}:5432/${var.database}?sslmode=require"
  })
}

output "kind" { value = "database.postgresql" }
output "host" { value = local.host }
output "port" { value = 5432 }
output "database" { value = google_sql_database.this.name }
output "username" { value = google_sql_user.app.name }
output "instance_name" { value = google_sql_database_instance.this.name }
output "connection_name" { value = google_sql_database_instance.this.connection_name }
# A reference, not a value: Cloud Run mounts it as a secret environment variable.
output "secret_ref" { value = google_secret_manager_secret.credentials.id }
