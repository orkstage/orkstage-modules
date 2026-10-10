# Logical "cache.redis" on DigitalOcean Managed Valkey (Redis compatible; DigitalOcean replaced
# Managed Caching for Redis with Valkey). Authentication is always on: the password stays in
# DigitalOcean and the module publishes a reference (do-db://<cluster id>).

variable "name" { type = string } # 3 to 63 chars
variable "region" { type = string }
variable "engine_version" {
  type    = string
  default = "8"
}
variable "size" { type = string }
# Primary plus standby nodes, 1 to 3.
variable "node_count" {
  type    = number
  default = 1
}
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "eviction_policy" {
  type    = string
  default = "allkeys_lru"
}
variable "tags" {
  type    = list(string)
  default = []
}

resource "digitalocean_database_cluster" "this" {
  name                 = var.name
  engine               = "valkey"
  version              = var.engine_version
  size                 = var.size
  region               = var.region
  node_count           = var.node_count
  private_network_uuid = var.vpc_id
  eviction_policy      = var.eviction_policy
  tags                 = var.tags
}

# Only resources inside the VPC may connect.
resource "digitalocean_database_firewall" "this" {
  cluster_id = digitalocean_database_cluster.this.id
  rule {
    type  = "ip_addr"
    value = var.vpc_cidr
  }
}

output "kind" { value = "cache.redis" }
output "cluster_id" { value = digitalocean_database_cluster.this.id }
output "cluster_name" { value = digitalocean_database_cluster.this.name }
output "host" { value = digitalocean_database_cluster.this.private_host }
output "port" { value = digitalocean_database_cluster.this.port }
output "tls" { value = true }
output "public_access" { value = false }
output "region" { value = var.region }
output "secret_ref" { value = "do-db://${digitalocean_database_cluster.this.id}" }
