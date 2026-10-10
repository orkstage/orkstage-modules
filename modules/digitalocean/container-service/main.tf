# Logical "compute.container-service" on DigitalOcean App Platform: one app with one service
# component running a prebuilt image. Connection strings of DigitalOcean managed databases are
# read here from the provider and stored by App Platform as encrypted (SECRET) variables; they
# never become module outputs.

variable "name" { type = string }   # app name, 2 to 32 chars
variable "region" { type = string } # App Platform region code, e.g. nyc, ams, fra
variable "component" {
  type    = string
  default = "service"
}
variable "image" {
  type = object({
    registry_type = string # DOCR, DOCKER_HUB or GHCR
    registry      = string # empty for DOCR
    repository    = string
    tag           = string # empty when digest is set
    digest        = string
  })
}
# Image reference as the template gave it, for display.
variable "image_ref" {
  type    = string
  default = ""
}
variable "instance_size_slug" { type = string }
variable "instance_count" {
  type    = number
  default = 1
}
# CPU based autoscaling (dedicated instance sizes only). null = fixed instance_count.
variable "autoscaling" {
  type = object({
    min_instance_count = number
    max_instance_count = number
    cpu_percent        = number
  })
  default = null
}
variable "port" {
  type    = number
  default = null
}
variable "public" {
  type    = bool
  default = true
}
variable "path_prefix" {
  type    = string
  default = "/"
}
variable "health_check_path" {
  type    = string
  default = ""
}
# Plain configuration (hosts, ports, bucket names). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
# ENV_PREFIX => DigitalOcean database cluster name. Each becomes <ENV_PREFIX>_URL as a SECRET.
variable "database_clusters" {
  type    = map(string)
  default = {}
}
# VPC to join (only in the datacenter App Platform pairs with the app region). Empty = none.
variable "vpc_id" {
  type    = string
  default = ""
}

data "digitalocean_database_cluster" "dep" {
  for_each = var.database_clusters
  name     = each.value
}

locals {
  scaled    = var.autoscaling != null
  http_port = var.public ? coalesce(var.port, 8080) : null
  private   = var.vpc_id != ""
}

resource "digitalocean_app" "this" {
  spec {
    name   = var.name
    region = var.region

    service {
      name               = var.component
      instance_size_slug = var.instance_size_slug
      instance_count     = local.scaled ? null : var.instance_count
      http_port          = local.http_port
      internal_ports     = !var.public && var.port != null ? [var.port] : null

      image {
        registry_type = var.image.registry_type
        registry      = var.image.registry == "" ? null : var.image.registry
        repository    = var.image.repository
        tag           = var.image.tag == "" ? null : var.image.tag
        digest        = var.image.digest == "" ? null : var.image.digest
      }

      dynamic "autoscaling" {
        for_each = local.scaled ? [var.autoscaling] : []
        content {
          min_instance_count = autoscaling.value.min_instance_count
          max_instance_count = autoscaling.value.max_instance_count
          metrics {
            cpu {
              percent = autoscaling.value.cpu_percent
            }
          }
        }
      }

      dynamic "health_check" {
        for_each = var.health_check_path != "" && local.http_port != null ? [1] : []
        content {
          http_path             = var.health_check_path
          initial_delay_seconds = 10
          period_seconds        = 10
          failure_threshold     = 6
        }
      }

      dynamic "env" {
        for_each = var.environment
        content {
          key   = env.key
          value = env.value
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
      }

      # Keys only drive the iteration; the connection string itself stays sensitive.
      dynamic "env" {
        for_each = var.database_clusters
        content {
          key   = "${env.key}_URL"
          value = local.private ? data.digitalocean_database_cluster.dep[env.key].private_uri : data.digitalocean_database_cluster.dep[env.key].uri
          scope = "RUN_TIME"
          type  = "SECRET"
        }
      }
    }

    dynamic "ingress" {
      for_each = var.public ? [1] : []
      content {
        rule {
          component {
            name                 = var.component
            preserve_path_prefix = true
          }
          match {
            path {
              prefix = var.path_prefix
            }
          }
        }
      }
    }

    dynamic "vpc" {
      for_each = local.private ? [1] : []
      content {
        id = var.vpc_id
      }
    }
  }
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = digitalocean_app.this.id }
output "app_id" { value = digitalocean_app.this.id }
output "component" { value = var.component }
output "url" { value = var.public ? digitalocean_app.this.live_url : "" }
output "health_check_path" { value = var.health_check_path }
output "path_prefix" { value = var.path_prefix }
output "default_ingress" { value = digitalocean_app.this.default_ingress }
output "image" { value = var.image_ref }
output "region" { value = var.region }
output "autoscaling" { value = local.scaled ? "${var.autoscaling.min_instance_count}-${var.autoscaling.max_instance_count} @ ${var.autoscaling.cpu_percent}% CPU" : "off" }
