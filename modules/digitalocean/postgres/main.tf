# Logical "database.postgresql" on DigitalOcean Managed PostgreSQL. DigitalOcean generates the
# default user's password and returns it through its API, so the module publishes a reference
# (do-db://<cluster id>) instead of the value. Trusted sources limit access to the VPC unless
# public access was asked for.

variable "name" { type = string } # 3 to 63 chars
variable "region" { type = string }
variable "engine_version" { type = string }
variable "size" { type = string }
variable "node_count" {
  type    = number
  default = 1
}
# null keeps the plan's default disk.
variable "storage_size_mib" {
  type    = number
  default = null
}
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "public_access" {
  type    = bool
  default = false
}
variable "tags" {
  type    = list(string)
  default = []
}

resource "digitalocean_database_cluster" "this" {
  name                 = var.name
  engine               = "pg"
  version              = var.engine_version
  size                 = var.size
  region               = var.region
  node_count           = var.node_count
  storage_size_mib     = var.storage_size_mib
  private_network_uuid = var.vpc_id
  tags                 = var.tags
}

# One firewall resource owns every trusted source rule of the cluster. Without rules the cluster
# accepts any address (still TLS and password protected), which is what public access means here.
resource "digitalocean_database_firewall" "this" {
  count      = var.public_access ? 0 : 1
  cluster_id = digitalocean_database_cluster.this.id
  rule {
    type  = "ip_addr"
    value = var.vpc_cidr
  }
}

output "kind" { value = "database.postgresql" }
output "cluster_id" { value = digitalocean_database_cluster.this.id }
output "cluster_name" { value = digitalocean_database_cluster.this.name }
output "host" { value = var.public_access ? digitalocean_database_cluster.this.host : digitalocean_database_cluster.this.private_host }
output "public_host" { value = digitalocean_database_cluster.this.host }
output "port" { value = digitalocean_database_cluster.this.port }
output "database" { value = digitalocean_database_cluster.this.database }
output "username" { value = digitalocean_database_cluster.this.user }
output "public_access" { value = var.public_access }
output "region" { value = var.region }
# A reference, not a value: the adapter reads the connection details from the DigitalOcean API.
output "secret_ref" { value = "do-db://${digitalocean_database_cluster.this.id}" }
