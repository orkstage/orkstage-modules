# Logical "database.postgresql" on OCI Database with PostgreSQL. The admin password is generated
# here and written to an OCI Vault secret (JSON: username, password, host, port, database, url);
# services receive the secret OCID, never the value. The vault and key come from the target, or
# a dedicated vault and software key are created when none is given.

variable "name" { type = string }
variable "compartment_id" { type = string }
variable "db_version" { type = string }
variable "shape" {
  type    = string
  default = "PostgreSQL.VM.Standard.E5.Flex"
}
variable "ocpus" { type = number }
variable "memory_gbs" { type = number }
# 1 = single node; more adds read replicas on regionally durable storage (high availability).
variable "instance_count" {
  type    = number
  default = 1
}
variable "backup_retention_days" { type = number }
variable "vcn_id" { type = string }
variable "vcn_cidr" { type = string }
variable "subnet_id" { type = string }
variable "username" {
  type    = string
  default = "app"
}
# Existing vault and AES key for the credentials secret. Empty = create a dedicated vault.
variable "vault_id" {
  type    = string
  default = ""
}
variable "key_id" {
  type    = string
  default = ""
}
variable "freeform_tags" {
  type    = map(string)
  default = {}
}

locals {
  own_vault = var.vault_id == ""
  vault_id  = local.own_vault ? oci_kms_vault.this[0].id : var.vault_id
  key_id    = local.own_vault ? oci_kms_key.this[0].id : var.key_id
  host      = oci_psql_db_system.this.network_details[0].primary_db_endpoint_private_ip
  flexible_configs = try([
    for c in data.oci_psql_default_configurations.this.default_configuration_collection[0].items : c.id
    if c.is_flexible && contains(c.compatible_shapes, var.shape)
  ], [])
}

data "oci_psql_default_configurations" "this" {
  db_version = var.db_version
}

resource "random_password" "admin" {
  length           = 24
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "-_!*"
}

# Secret names stay reserved while a deleted secret is pending deletion; a suffix lets the same
# database be created again right away.
resource "random_id" "secret" {
  byte_length = 3
}

resource "oci_kms_vault" "this" {
  count          = local.own_vault ? 1 : 0
  compartment_id = var.compartment_id
  display_name   = "${var.name}-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = var.freeform_tags
}

resource "oci_kms_key" "this" {
  count               = local.own_vault ? 1 : 0
  compartment_id      = var.compartment_id
  display_name        = "${var.name}-key"
  management_endpoint = oci_kms_vault.this[0].management_endpoint
  protection_mode     = "SOFTWARE"
  freeform_tags       = var.freeform_tags
  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

resource "oci_core_network_security_group" "db" {
  compartment_id = var.compartment_id
  vcn_id         = var.vcn_id
  display_name   = "${var.name}-db"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_network_security_group_security_rule" "postgres" {
  network_security_group_id = oci_core_network_security_group.db.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      min = 5432
      max = 5432
    }
  }
}

resource "oci_psql_db_system" "this" {
  compartment_id              = var.compartment_id
  display_name                = var.name
  db_version                  = var.db_version
  shape                       = var.shape
  instance_ocpu_count         = var.ocpus
  instance_memory_size_in_gbs = var.memory_gbs
  instance_count              = var.instance_count
  config_id                   = length(local.flexible_configs) > 0 ? local.flexible_configs[0] : null
  freeform_tags               = var.freeform_tags

  credentials {
    username = var.username
    password_details {
      password_type = "PLAIN_TEXT"
      password      = random_password.admin.result
    }
  }

  network_details {
    subnet_id = var.subnet_id
    nsg_ids   = [oci_core_network_security_group.db.id]
  }

  storage_details {
    system_type           = "OCI_OPTIMIZED_STORAGE"
    is_regionally_durable = true
  }

  management_policy {
    backup_policy {
      kind           = var.backup_retention_days > 0 ? "DAILY" : "NONE"
      backup_start   = var.backup_retention_days > 0 ? "02:00" : null
      retention_days = var.backup_retention_days > 0 ? var.backup_retention_days : null
    }
  }

  lifecycle {
    ignore_changes = [config_id]
  }
}

resource "oci_vault_secret" "credentials" {
  compartment_id = var.compartment_id
  vault_id       = local.vault_id
  key_id         = local.key_id
  secret_name    = "${var.name}-credentials-${random_id.secret.hex}"
  description    = "OrkStage credentials for ${var.name}"
  freeform_tags  = var.freeform_tags
  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      engine   = "postgres"
      username = var.username
      password = random_password.admin.result
      host     = local.host
      port     = "5432"
      database = "postgres"
      url      = "postgresql://${var.username}:${random_password.admin.result}@${local.host}:5432/postgres?sslmode=require"
    }))
  }
}

output "kind" { value = "database.postgresql" }
output "id" { value = oci_psql_db_system.this.id }
output "host" { value = local.host }
output "port" { value = 5432 }
output "database" { value = "postgres" }
output "username" { value = var.username }
# A reference, not a value: the OCID of the Vault secret holding the credentials.
output "secret_ref" { value = oci_vault_secret.credentials.id }
