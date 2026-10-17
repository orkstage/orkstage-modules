# Logical "network" on Google Cloud: a custom mode VPC with one regional subnet, a private
# services access range (Cloud SQL and Memorystore take their private IPs from it) and an
# optional Cloud NAT for outbound traffic with no public IPs.

variable "name" { type = string }
variable "region" { type = string }
variable "subnet_cidr" { type = string }
variable "nat_gateway" {
  type    = bool
  default = false
}
variable "services_prefix_length" {
  type    = number
  default = 16
}

resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name                     = var.name
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

resource "google_compute_global_address" "services" {
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.services_prefix_length
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "services" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.services.name]
  # Google keeps producer resources (a deleted Cloud SQL instance) for a while, which makes
  # removing the peering fail. Abandon it instead; it goes away with the network.
  deletion_policy = "ABANDON"
}

resource "google_compute_router" "this" {
  count   = var.nat_gateway ? 1 : 0
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

# A reserved address (instead of AUTO_ONLY) gives the network a fixed egress for allowlists.
resource "google_compute_address" "nat" {
  count  = var.nat_gateway ? 1 : 0
  name   = "${var.name}-nat"
  region = var.region
}

resource "google_compute_router_nat" "this" {
  count                              = var.nat_gateway ? 1 : 0
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this[0].name
  region                             = var.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = google_compute_address.nat[*].self_link
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

output "kind" { value = "network" }
output "network_id" { value = google_compute_network.this.id }
output "network_name" { value = google_compute_network.this.name }
output "subnet_id" { value = google_compute_subnetwork.this.id }
output "subnet_name" { value = google_compute_subnetwork.this.name }
output "cidr" { value = google_compute_subnetwork.this.ip_cidr_range }
output "region" { value = var.region }
output "services_range" { value = google_compute_global_address.services.name }
output "nat" { value = var.nat_gateway }
output "private_egress" { value = var.nat_gateway }
# Fixed public address of the Cloud NAT, for allowlists on other providers.
output "egress_ips" { value = join(",", google_compute_address.nat[*].address) }
