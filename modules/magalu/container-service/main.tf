# Logical "compute.container-service" on Magalu Cloud virtual machines: each replica is a VM that
# installs Docker through cloud-init and runs the image with host networking. The machine type is
# the smallest Balanced Value type that fits the requested vCPU and memory, unless one is given.
# Every VM gets a public IPv4 (needed to pull images); inbound traffic is limited by a security
# group to the service port. With `load_balancer`, a network load balancer spreads traffic over
# the VMs. Environment values are plain configuration: they end up in VM user data.

variable "name" { type = string }
variable "image" { type = string }
variable "replicas" { type = number }
variable "min_vcpu" { type = number }
variable "min_ram_gib" { type = number }
# Explicit machine type, e.g. "BV2-4-40". Empty = chosen from the catalog.
variable "machine_type" {
  type    = string
  default = ""
}
variable "min_disk_gib" {
  type    = number
  default = 20
}
variable "vm_image" {
  type    = string
  default = "cloud-ubuntu-24.04 LTS"
}
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
  default = "/"
}
variable "load_balancer" {
  type    = bool
  default = false
}
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
variable "subnet_id" { type = string }
variable "subnetpool_id" { type = string }
variable "availability_zone" { type = string }
variable "internal_sg_id" { type = string }
# Plain configuration (hosts, ports, URLs, secret references). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
# Existing SSH key name in the tenant. Empty = a key is generated for this service.
variable "ssh_key_name" {
  type    = string
  default = ""
}

data "mgc_virtual_machine_types" "all" {}

locals {
  # Labels look like BV2-4-40: family, vCPU, RAM in GiB, disk in GiB.
  parsed = [
    for t in data.mgc_virtual_machine_types.all.machine_types : {
      name = t.name
      vcpu = tonumber(regex("^BV(\\d+)-(\\d+)-(\\d+)$", t.name)[0])
      ram  = tonumber(regex("^BV(\\d+)-(\\d+)-(\\d+)$", t.name)[1])
      disk = tonumber(regex("^BV(\\d+)-(\\d+)-(\\d+)$", t.name)[2])
    } if can(regex("^BV(\\d+)-(\\d+)-(\\d+)$", t.name)) && t.gpu == 0
  ]
  fits         = [for t in local.parsed : t if t.vcpu >= var.min_vcpu && t.ram >= var.min_ram_gib && t.disk >= var.min_disk_gib]
  ranked       = sort([for t in local.fits : format("%04d-%05d-%06d|%s", t.vcpu, t.ram, t.disk, t.name)])
  machine_type = var.machine_type != "" ? var.machine_type : (length(local.ranked) > 0 ? split("|", local.ranked[0])[1] : "")
  ssh_key_name = var.ssh_key_name != "" ? var.ssh_key_name : mgc_ssh_keys.generated[0].name

  env_file = join("\n", concat([for k, v in var.environment : "${k}=${v}"], [""]))
  cloud_config = "#cloud-config\n${yamlencode({
    package_update = true
    packages       = ["docker.io"]
    write_files = [{
      path        = "/etc/orkstage/app.env"
      permissions = "0600"
      content     = local.env_file
    }]
    runcmd = [
      ["systemctl", "enable", "--now", "docker"],
      ["docker", "run", "-d", "--name", "app", "--restart", "always", "--network", "host", "--env-file", "/etc/orkstage/app.env", var.image],
    ]
  })}"
}

resource "tls_private_key" "ssh" {
  count     = var.ssh_key_name == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "mgc_ssh_keys" "generated" {
  count = var.ssh_key_name == "" ? 1 : 0
  name  = var.name
  key   = trimspace(tls_private_key.ssh[0].public_key_openssh)
}

resource "mgc_network_security_groups" "service" {
  name        = var.name
  description = "Service ${var.name}"
}

resource "mgc_network_security_groups_rules" "port" {
  count             = var.port == null ? 0 : 1
  security_group_id = mgc_network_security_groups.service.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = var.port
  port_range_max    = var.port
  remote_ip_prefix  = var.public ? "0.0.0.0/0" : var.vpc_cidr
  description       = "Service port"
}

resource "mgc_virtual_machine_instances" "this" {
  count                    = var.replicas
  name                     = "${var.name}-${count.index}"
  machine_type             = local.machine_type
  image                    = var.vm_image
  ssh_key_name             = local.ssh_key_name
  user_data                = base64encode(local.cloud_config)
  vpc_id                   = var.vpc_id
  availability_zone        = var.availability_zone
  creation_subnets         = [var.subnet_id]
  creation_security_groups = [mgc_network_security_groups.service.id, var.internal_sg_id]

  lifecycle {
    precondition {
      condition     = local.machine_type != ""
      error_message = "No Balanced Value machine type has at least ${var.min_vcpu} vCPU, ${var.min_ram_gib} GiB of RAM and ${var.min_disk_gib} GiB of disk."
    }
  }
}

# Public IPs are separate resources so they are released when the service is destroyed.
resource "mgc_network_public_ips" "vm" {
  count       = var.replicas
  vpc_id      = var.vpc_id
  description = "${var.name}-${count.index}"
}

resource "mgc_network_public_ips_attach" "vm" {
  count        = var.replicas
  public_ip_id = mgc_network_public_ips.vm[count.index].id
  interface_id = mgc_virtual_machine_instances.this[count.index].network_interface_id
}

resource "mgc_network_public_ips" "lb" {
  count       = var.load_balancer ? 1 : 0
  vpc_id      = var.vpc_id
  description = "${var.name}-lb"
}

resource "mgc_lbaas_network" "this" {
  count         = var.load_balancer ? 1 : 0
  name          = var.name
  description   = "Service ${var.name}"
  type          = "proxy"
  visibility    = "external"
  vpc_id        = var.vpc_id
  subnetpool_id = var.subnetpool_id
  public_ip_id  = mgc_network_public_ips.lb[0].id

  backends = [{
    name              = "app"
    balance_algorithm = "round_robin"
    targets_type      = "instance"
    health_check_name = "app"
    targets = [for vm in mgc_virtual_machine_instances.this : {
      nic_id = vm.network_interface_id
      port   = var.port
    }]
  }]

  health_checks = [{
    name     = "app"
    protocol = "http"
    port     = var.port
    path     = var.health_path
  }]

  listeners = [{
    name         = "http"
    port         = 80
    protocol     = "tcp"
    backend_name = "app"
  }]

  acls = [{
    name             = "allow-all"
    action           = "ALLOW"
    ethertype        = "IPv4"
    protocol         = "tcp"
    remote_ip_prefix = "0.0.0.0/0"
  }]

  lifecycle {
    precondition {
      condition     = var.port != null
      error_message = "A load balanced service needs a port."
    }
  }
}

locals {
  public_ips  = mgc_network_public_ips.vm[*].public_ip
  private_ips = mgc_virtual_machine_instances.this[*].local_ipv4
  url = (
    var.load_balancer ? "http://${mgc_network_public_ips.lb[0].public_ip}" :
    var.port == null || var.replicas == 0 ? "" :
    var.public ? "http://${local.public_ips[0]}:${var.port}" :
    "http://${local.private_ips[0]}:${var.port}"
  )
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = var.name }
output "instance_ids" { value = join(",", mgc_virtual_machine_instances.this[*].id) }
output "public_ips" { value = join(",", local.public_ips) }
output "private_ips" { value = join(",", local.private_ips) }
output "load_balancer_id" { value = var.load_balancer ? mgc_lbaas_network.this[0].id : "" }
output "machine_type" { value = local.machine_type }
output "image" { value = var.image }
output "url" { value = local.url }
