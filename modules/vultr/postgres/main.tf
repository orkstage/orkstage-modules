# Logical "database.postgresql" on Vultr Managed Databases for PostgreSQL. Vultr generates the
# admin password; it stays in state and in the Vultr API, and services get a reference to it
# (`vultr-db://<id>`), never the value.

variable "name" { type = string }
variable "region" { type = string }
# Managed database plan id, picked by the adapter from size and high availability.
variable "plan" { type = string }
# Logical size the plan was picked for, recorded so the adapter keeps the same plan.
variable "size_key" { type = string }
variable "engine_version" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
# false = only the VPC may connect.
variable "public_access" {
  type    = bool
  default = false
}
variable "cluster_time_zone" {
  type    = string
  default = "UTC"
}
variable "tag" {
  type    = string
  default = ""
}

resource "vultr_database" "this" {
  database_engine         = "pg"
  database_engine_version = var.engine_version
  region                  = var.region
  plan                    = var.plan
  label                   = var.name
  tag                     = var.tag
  vpc_id                  = var.vpc_id
  trusted_ips             = var.public_access ? null : [var.vpc_cidr]
  cluster_time_zone       = var.cluster_time_zone
}

output "kind" { value = "database.postgresql" }
output "id" { value = vultr_database.this.id }
output "host" { value = vultr_database.this.host }
output "public_host" { value = vultr_database.this.public_host }
output "port" { value = tonumber(vultr_database.this.port) }
output "database" { value = vultr_database.this.dbname }
output "username" { value = vultr_database.this.user }
output "plan" { value = vultr_database.this.plan }
output "size_key" { value = var.size_key }
output "engine_version" { value = vultr_database.this.database_engine_version }
# A reference, not a value: the adapter reads the credentials from the Vultr API on demand.
output "secret_ref" { value = "vultr-db://${vultr_database.this.id}" }
