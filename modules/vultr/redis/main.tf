# Logical "cache.redis" on Vultr Managed Databases for Caching (Valkey, Redis compatible, TLS
# only). Replicas are standby nodes of the plan.

variable "name" { type = string }
variable "region" { type = string }
# Managed database plan id, picked by the adapter from size and replicas.
variable "plan" { type = string }
variable "size_key" { type = string }
variable "engine_version" {
  type    = string
  default = "7"
}
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "eviction_policy" {
  type    = string
  default = "allkeys-lru"
}
variable "tag" {
  type    = string
  default = ""
}

resource "vultr_database" "this" {
  database_engine         = "valkey"
  database_engine_version = var.engine_version
  region                  = var.region
  plan                    = var.plan
  label                   = var.name
  tag                     = var.tag
  vpc_id                  = var.vpc_id
  trusted_ips             = [var.vpc_cidr]
  eviction_policy         = var.eviction_policy
}

output "kind" { value = "cache.redis" }
output "id" { value = vultr_database.this.id }
output "host" { value = vultr_database.this.host }
output "port" { value = tonumber(vultr_database.this.port) }
output "username" { value = vultr_database.this.user }
output "tls" { value = true }
output "plan" { value = vultr_database.this.plan }
output "size_key" { value = var.size_key }
output "secret_ref" { value = "vultr-db://${vultr_database.this.id}" }
