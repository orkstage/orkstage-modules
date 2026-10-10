# Logical "compute.container-service" on Cloud Run (v2 API). Each service runs as its own
# service account, which may read exactly the secrets it references and write the buckets it
# depends on. With a network, Direct VPC egress places instances in the subnet so they reach
# private IPs (Cloud SQL, Memorystore) without a connector.

variable "name" { type = string }
variable "region" { type = string }
variable "service_account_id" { type = string } # 6 to 30 characters
variable "image" { type = string }
variable "cpu" { type = string }    # "1", "2", "4", "6" or "8"
variable "memory" { type = string } # e.g. "512Mi"
variable "port" {
  type    = number
  default = null
}
variable "min_instances" { type = number }
variable "max_instances" { type = number }
variable "public" {
  type    = bool
  default = false
}
variable "health_check_path" {
  type    = string
  default = ""
}
variable "network_id" {
  type    = string
  default = ""
}
variable "subnet_id" {
  type    = string
  default = ""
}
variable "egress" {
  type    = string
  default = "PRIVATE_RANGES_ONLY"
  validation {
    condition     = contains(["ALL_TRAFFIC", "PRIVATE_RANGES_ONLY"], var.egress)
    error_message = "egress must be ALL_TRAFFIC or PRIVATE_RANGES_ONLY."
  }
}
# Plain configuration (hosts, ports, URLs). Never secret values.
variable "environment" {
  type    = map(string)
  default = {}
}
# NAME => Secret Manager secret (projects/<p>/secrets/<s>), mounted by Cloud Run at start;
# values never pass through OpenTofu.
variable "secrets" {
  type    = map(string)
  default = {}
}
# Buckets the service may read and write.
variable "buckets" {
  type    = list(string)
  default = []
}
variable "production" {
  type    = bool
  default = false
}

resource "google_service_account" "this" {
  account_id   = var.service_account_id
  display_name = "OrkStage ${var.name}"
}

resource "google_secret_manager_secret_iam_member" "secrets" {
  for_each  = toset(values(var.secrets))
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.this.email}"
}

resource "google_storage_bucket_iam_member" "buckets" {
  for_each = toset(var.buckets)
  bucket   = each.value
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${google_service_account.this.email}"
}

resource "google_cloud_run_v2_service" "this" {
  name                 = var.name
  location             = var.region
  ingress              = var.public ? "INGRESS_TRAFFIC_ALL" : "INGRESS_TRAFFIC_INTERNAL_ONLY"
  invoker_iam_disabled = var.public
  deletion_protection  = var.production

  template {
    service_account = google_service_account.this.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    dynamic "vpc_access" {
      for_each = var.subnet_id == "" ? [] : [1]
      content {
        egress = var.egress
        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
        }
      }
    }

    containers {
      image = var.image

      dynamic "ports" {
        for_each = var.port == null ? [] : [var.port]
        content {
          container_port = ports.value
        }
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle = true
      }

      dynamic "env" {
        for_each = var.environment
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      dynamic "startup_probe" {
        for_each = var.health_check_path == "" ? [] : [1]
        content {
          http_get {
            path = var.health_check_path
          }
        }
      }

      dynamic "liveness_probe" {
        for_each = var.health_check_path == "" ? [] : [1]
        content {
          http_get {
            path = var.health_check_path
          }
        }
      }
    }
  }

  # Secret access must exist before the first revision starts, or it fails to mount them.
  depends_on = [google_secret_manager_secret_iam_member.secrets, google_storage_bucket_iam_member.buckets]
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = google_cloud_run_v2_service.this.id }
output "service_name" { value = google_cloud_run_v2_service.this.name }
output "url" { value = var.public ? google_cloud_run_v2_service.this.uri : "" }
output "service_uri" { value = google_cloud_run_v2_service.this.uri }
output "image" { value = var.image }
output "service_account" { value = google_service_account.this.email }
