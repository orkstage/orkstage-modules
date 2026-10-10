# Logical "compute.container-service" on Vultr cloud compute. Vultr has no serverless containers,
# so each replica is one instance that installs Docker through cloud init and runs `image` with
# the service environment. Instances join the VPC; the firewall group opens the service port to
# the VPC only, or to everyone when the service is public without a load balancer.
#
# A change to the image, environment or size replaces the instances (create before destroy).
# The adapter attaches the instances to the ingress load balancer after each apply.

variable "name" { type = string }
variable "region" { type = string }
# Cloud compute plan id, e.g. vc2-1c-1gb, picked by the adapter from cpu and memory.
variable "plan" { type = string }
# Ubuntu 24.04 LTS x64.
variable "os_id" {
  type    = number
  default = 2284
}
variable "image" { type = string }
variable "cpu" { type = number } # vCPU, e.g. 0.25
variable "memory_mib" { type = number }
variable "replicas" { type = number }
variable "port" {
  type    = number
  default = null
}
variable "public" {
  type    = bool
  default = false
}
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }
# Plain configuration (hosts, ports, URLs). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
variable "tags" {
  type    = list(string)
  default = []
}
# Load balancer of the ingress that routes to this service, and its public URL.
variable "lb_id" {
  type    = string
  default = ""
}
variable "ingress_url" {
  type    = string
  default = ""
}
# When true, credentials of the managed databases and object storage subscriptions below are
# read here and written into the instance user data (visible to account administrators).
variable "inject_credentials" {
  type    = bool
  default = false
}
# ENV_PREFIX => Vultr managed database id.
variable "database_refs" {
  type    = map(string)
  default = {}
}
# ENV_PREFIX => Vultr object storage subscription id.
variable "object_storage_refs" {
  type    = map(string)
  default = {}
}

data "vultr_database" "dep" {
  for_each = var.inject_credentials ? var.database_refs : {}
  filter {
    name   = "id"
    values = [each.value]
  }
}

data "vultr_object_storage" "dep" {
  for_each = var.inject_credentials ? var.object_storage_refs : {}
  filter {
    name   = "id"
    values = [each.value]
  }
}

locals {
  database_env = { for pair in flatten([for k, db in data.vultr_database.dep : [
    {
      key = "${k}_URL"
      value = db.database_engine == "pg" ? (
        "postgresql://${urlencode(db.user)}:${urlencode(db.password)}@${db.host}:${db.port}/${db.dbname}?sslmode=require"
      ) : "rediss://${urlencode(db.user)}:${urlencode(db.password)}@${db.host}:${db.port}"
    },
    { key = "${k}_USERNAME", value = db.user },
    { key = "${k}_PASSWORD", value = db.password },
  ]]) : pair.key => pair.value }

  storage_env = { for pair in flatten([for k, s in data.vultr_object_storage.dep : [
    { key = "${k}_ACCESS_KEY_ID", value = s.s3_access_key },
    { key = "${k}_SECRET_ACCESS_KEY", value = s.s3_secret_key },
  ]]) : pair.key => pair.value }

  env = merge(
    var.environment,
    var.port == null ? {} : { PORT = tostring(var.port) },
    local.database_env,
    local.storage_env,
  )

  docker_run = concat(
    ["docker", "run", "-d", "--name", "app", "--restart", "always", "--env-file", "/etc/orkstage/app.env"],
    ["--memory", "${var.memory_mib}m", "--cpus", tostring(var.cpu)],
    var.port == null ? [] : ["-p", "${var.port}:${var.port}"],
    [var.image],
  )

  user_data = "#cloud-config\n${yamlencode({
    package_update = true
    packages       = ["docker.io"]
    write_files = [{
      path        = "/etc/orkstage/app.env"
      permissions = "0600"
      owner       = "root:root"
      content     = "${join("\n", [for k, v in local.env : "${k}=${v}"])}\n"
    }]
    runcmd = [
      ["systemctl", "enable", "--now", "docker"],
      local.docker_run,
    ]
  })}"

  public_url = length(vultr_instance.this) > 0 && var.port != null ? "http://${vultr_instance.this[0].main_ip}:${var.port}" : ""
}

# Replaces the instances whenever what runs on them changes: cloud init only runs at first boot.
resource "terraform_data" "revision" {
  input = sha256("${var.plan}|${var.os_id}|${local.user_data}")
}

resource "vultr_firewall_group" "this" {
  description = var.name
}

resource "vultr_firewall_rule" "vpc" {
  count             = var.port == null ? 0 : 1
  firewall_group_id = vultr_firewall_group.this.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", var.vpc_cidr)[0]
  subnet_size       = tonumber(split("/", var.vpc_cidr)[1])
  port              = tostring(var.port)
  notes             = "VPC and load balancer"
}

resource "vultr_firewall_rule" "public" {
  count             = var.port != null && var.public && var.lb_id == "" ? 1 : 0
  firewall_group_id = vultr_firewall_group.this.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = tostring(var.port)
  notes             = "Public service"
}

resource "vultr_instance" "this" {
  count             = var.replicas
  region            = var.region
  plan              = var.plan
  os_id             = var.os_id
  label             = "${var.name}-${count.index}"
  hostname          = "${var.name}-${count.index}"
  tags              = var.tags
  vpc_ids           = [var.vpc_id]
  firewall_group_id = vultr_firewall_group.this.id
  user_data         = local.user_data
  backups           = "disabled"
  enable_ipv6       = false
  activation_email  = false
  ddos_protection   = false
  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.revision]
  }
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = var.name }
output "instance_ids" { value = join(",", vultr_instance.this[*].id) }
output "host" { value = length(vultr_instance.this) > 0 ? vultr_instance.this[0].internal_ip : "" }
output "port" { value = var.port }
output "url" { value = var.public ? (var.ingress_url != "" ? var.ingress_url : local.public_url) : "" }
output "image" { value = var.image }
output "plan" { value = var.plan }
output "replicas" { value = var.replicas }
output "lb_id" { value = var.lb_id }
output "firewall_group_id" { value = vultr_firewall_group.this.id }
