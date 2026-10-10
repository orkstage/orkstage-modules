# Logical "cache.redis" on Memorystore for Redis, reached through the network's private
# services access connection, with AUTH on. The AUTH string is copied into a Secret Manager
# secret; outputs carry the secret's resource name, never the value.

variable "name" { type = string } # at most 40 characters
variable "region" { type = string }
variable "tier" {
  type    = string
  default = "BASIC"
  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.tier)
    error_message = "tier must be BASIC or STANDARD_HA."
  }
}
variable "memory_size_gb" { type = number }
variable "replica_count" {
  type    = number
  default = 0
}
variable "read_replicas" {
  type    = bool
  default = false
}
variable "network_id" { type = string }
variable "production" {
  type    = bool
  default = false
}

resource "google_redis_instance" "this" {
  name                = var.name
  region              = var.region
  tier                = var.tier
  memory_size_gb      = var.memory_size_gb
  authorized_network  = var.network_id
  connect_mode        = "PRIVATE_SERVICE_ACCESS"
  auth_enabled        = true
  replica_count       = var.tier == "STANDARD_HA" ? var.replica_count : null
  read_replicas_mode  = var.tier == "STANDARD_HA" ? (var.read_replicas ? "READ_REPLICAS_ENABLED" : "READ_REPLICAS_DISABLED") : null
  deletion_protection = var.production
}

resource "google_secret_manager_secret" "auth" {
  secret_id = "${var.name}-auth"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "auth" {
  secret = google_secret_manager_secret.auth.id
  secret_data = jsonencode({
    password = google_redis_instance.this.auth_string
    host     = google_redis_instance.this.host
    port     = google_redis_instance.this.port
    url      = "redis://:${google_redis_instance.this.auth_string}@${google_redis_instance.this.host}:${google_redis_instance.this.port}"
  })
}

output "kind" { value = "cache.redis" }
output "host" { value = google_redis_instance.this.host }
output "port" { value = google_redis_instance.this.port }
output "instance_id" { value = google_redis_instance.this.id }
output "secret_ref" { value = google_secret_manager_secret.auth.id }
