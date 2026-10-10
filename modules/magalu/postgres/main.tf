# Logical "database.postgresql" on Magalu Cloud DBaaS. A single instance, or a Multi AZ cluster
# when high availability is zone redundant. The instance type is the smallest one in the region
# that fits the requested size, unless one is given. The master password is generated here and
# written to DBaaS through a write only attribute; it stays only in this resource's OpenTofu state
# (in the customer's own bucket), which the adapter reads to answer `secret_ref`.

variable "name" { type = string }
variable "engine_version" { type = string } # e.g. "16"
variable "min_vcpu" { type = number }
variable "min_ram_gib" { type = number }
# Instance type family to prefer: BV (balanced value) or DP (dedicated performance).
variable "family" {
  type    = string
  default = "BV"
}
# Explicit instance type label, e.g. "DP2-16-40". Empty = chosen from the catalog.
variable "instance_type" {
  type    = string
  default = ""
}
variable "volume_size_gib" { type = number }
variable "volume_type" {
  type    = string
  default = "CLOUD_NVME15K"
}
variable "backup_retention_days" {
  type    = number
  default = 7
}
variable "high_availability" {
  type    = bool
  default = false
}
variable "production" {
  type    = bool
  default = false
}
variable "username" {
  type    = string
  default = "app"
}

data "mgc_dbaas_engines" "active" {
  status = "ACTIVE"
}

data "mgc_dbaas_instance_types" "active" {}

locals {
  pg_versions = [for e in data.mgc_dbaas_engines.active.engines : e.version if lower(e.name) == "postgresql"]

  # Labels look like BV2-4-10 or DP2-16-40: family, vCPU, RAM in GiB, then a disk or tier figure.
  parsed = [
    for t in data.mgc_dbaas_instance_types.active.instance_types : {
      name   = t.name
      family = regex("^([A-Z]+)(\\d+)-(\\d+)", t.name)[0]
      vcpu   = tonumber(regex("^([A-Z]+)(\\d+)-(\\d+)", t.name)[1])
      ram    = tonumber(regex("^([A-Z]+)(\\d+)-(\\d+)", t.name)[2])
    } if can(regex("^([A-Z]+)(\\d+)-(\\d+)", t.name))
  ]
  fits      = [for t in local.parsed : t if t.vcpu >= var.min_vcpu && t.ram >= var.min_ram_gib]
  preferred = [for t in local.fits : t if t.family == var.family]
  pool      = length(local.preferred) > 0 ? local.preferred : local.fits
  ranked    = sort([for t in local.pool : format("%04d-%05d|%s", t.vcpu, t.ram, t.name)])
  chosen    = var.instance_type != "" ? var.instance_type : (length(local.ranked) > 0 ? split("|", local.ranked[0])[1] : "")
}

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "-_!*"
  min_special      = 2
  min_numeric      = 2
  min_upper        = 2
  min_lower        = 2
}

resource "mgc_dbaas_instances" "this" {
  count                 = var.high_availability ? 0 : 1
  name                  = var.name
  engine_name           = "postgresql"
  engine_version        = var.engine_version
  instance_type         = local.chosen
  volume_size           = var.volume_size_gib
  volume_type           = var.volume_type
  user                  = var.username
  password              = random_password.master.result
  backup_retention_days = var.backup_retention_days
  deletion_protected    = var.production

  lifecycle {
    precondition {
      condition     = contains(local.pg_versions, var.engine_version)
      error_message = "PostgreSQL ${var.engine_version} is not offered by Magalu Cloud DBaaS in this region. Active versions: ${join(", ", local.pg_versions)}."
    }
    precondition {
      condition     = local.chosen != ""
      error_message = "No DBaaS instance type has at least ${var.min_vcpu} vCPU and ${var.min_ram_gib} GiB of RAM."
    }
  }
}

resource "mgc_dbaas_clusters" "this" {
  count                 = var.high_availability ? 1 : 0
  name                  = var.name
  engine_name           = "postgresql"
  engine_version        = var.engine_version
  instance_type         = local.chosen
  volume_size           = var.volume_size_gib
  volume_type           = var.volume_type
  user                  = var.username
  password              = random_password.master.result
  backup_retention_days = var.backup_retention_days
  deletion_protected    = var.production

  lifecycle {
    precondition {
      condition     = contains(local.pg_versions, var.engine_version)
      error_message = "PostgreSQL ${var.engine_version} is not offered by Magalu Cloud DBaaS in this region. Active versions: ${join(", ", local.pg_versions)}."
    }
    precondition {
      condition     = local.chosen != ""
      error_message = "No DBaaS instance type has at least ${var.min_vcpu} vCPU and ${var.min_ram_gib} GiB of RAM."
    }
  }
}

# The instance resource does not expose its addresses; the data source does.
data "mgc_dbaas_instance" "this" {
  count = var.high_availability ? 0 : 1
  id    = mgc_dbaas_instances.this[0].id
}

locals {
  id = var.high_availability ? mgc_dbaas_clusters.this[0].id : mgc_dbaas_instances.this[0].id
  instance_hosts = var.high_availability ? [] : [
    for a in data.mgc_dbaas_instance.this[0].addresses : a.address if lower(a.access) == "private" && a.type == "IPv4"
  ]
  cluster_hosts = var.high_availability ? [
    for a in mgc_dbaas_clusters.this[0].addresses : a.address if lower(a.access) == "private" && upper(a.purpose) == "READ_WRITE"
  ] : []
  host = try(concat(local.cluster_hosts, local.instance_hosts)[0], "")
}

output "kind" { value = "database.postgresql" }
output "instance_id" { value = local.id }
output "deployment" { value = var.high_availability ? "cluster" : "instance" }
output "instance_type" { value = local.chosen }
output "host" { value = local.host }
output "port" { value = 5432 }
output "database" { value = "postgres" }
output "username" { value = var.username }
# A reference, not a value: the adapter resolves it from this resource's state.
output "secret_ref" { value = "mgc-db://${var.name}/${local.id}" }
