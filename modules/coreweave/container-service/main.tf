# Logical "compute.container-service" on CoreWeave Kubernetes Service: a Deployment and a Service
# in a namespace of its own on the target's existing CKS cluster. GPUs are requested through the
# nvidia.com/gpu resource and pinned to a GPU class with node affinity. A public service gets a
# LoadBalancer with a public IP; a service routed by an ingress gets an Ingress object.

variable "name" { type = string } # namespace and workload name
variable "image" { type = string }
variable "replicas" {
  type    = number
  default = 1
}
variable "cpu_millicores" {
  type    = number
  default = 250
}
variable "memory_mib" {
  type    = number
  default = 512
}
variable "port" {
  type    = number
  default = null
}
variable "public" {
  type    = bool
  default = false
}
variable "health_check_path" {
  type    = string
  default = null
}
variable "environment" {
  type    = map(string)
  default = {}
}
variable "secret_env" {
  # Credentials of dependencies on other providers, stored as a Kubernetes Secret.
  type      = map(string)
  default   = {}
  sensitive = true
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "gpu" {
  type = object({
    count = number
    class = optional(string)
  })
  default = null
}
variable "autoscaling" {
  type = object({
    min_replicas       = number
    max_replicas       = number
    target_cpu_percent = number
  })
  default = null
}
variable "route" {
  type = object({
    host           = string
    path_prefix    = string
    ingress_class  = string
    tls            = bool
    cluster_issuer = string
  })
  default = null
}

locals {
  selector    = { "app.kubernetes.io/name" = var.name }
  labels      = merge(var.labels, local.selector, { "app.kubernetes.io/managed-by" = "orkstage" })
  limits      = merge({ memory = "${var.memory_mib}Mi" }, var.gpu == null ? {} : { "nvidia.com/gpu" = tostring(var.gpu.count) })
  gpu_classes = var.gpu == null ? [] : (var.gpu.class == null ? [] : [var.gpu.class])
  routed      = var.route != null && var.port != null
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.name
    labels = local.labels
  }
}

resource "kubernetes_secret_v1" "deps" {
  metadata {
    name      = "${var.name}-deps"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  data = var.secret_env
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    # With autoscaling the HorizontalPodAutoscaler owns the replica count.
    replicas = var.autoscaling == null ? var.replicas : null

    selector {
      match_labels = local.selector
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        dynamic "affinity" {
          for_each = length(local.gpu_classes) > 0 ? [1] : []
          content {
            node_affinity {
              required_during_scheduling_ignored_during_execution {
                node_selector_term {
                  match_expressions {
                    key      = "gpu.nvidia.com/class"
                    operator = "In"
                    values   = local.gpu_classes
                  }
                }
              }
            }
          }
        }

        container {
          name  = "app"
          image = var.image

          dynamic "port" {
            for_each = var.port == null ? [] : [var.port]
            content {
              container_port = port.value
            }
          }

          dynamic "env" {
            for_each = var.environment
            content {
              name  = env.key
              value = env.value
            }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.deps.metadata[0].name
            }
          }

          resources {
            requests = { cpu = "${var.cpu_millicores}m", memory = "${var.memory_mib}Mi" }
            limits   = local.limits
          }

          dynamic "readiness_probe" {
            for_each = var.port != null && var.health_check_path != null ? [1] : []
            content {
              http_get {
                path = var.health_check_path
                port = var.port
              }
              period_seconds = 10
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  lifecycle {
    # The restart action sets a pod template annotation (rollout restart); OpenTofu must not undo it.
    ignore_changes = [spec[0].template[0].metadata[0].annotations]
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "this" {
  count = var.autoscaling == null ? 0 : 1
  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    min_replicas = var.autoscaling.min_replicas
    max_replicas = var.autoscaling.max_replicas
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.this.metadata[0].name
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.autoscaling.target_cpu_percent
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "this" {
  count = var.port == null ? 0 : 1
  metadata {
    name      = var.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
    # Without this annotation CKS assigns a private address.
    annotations = var.public ? { "service.beta.kubernetes.io/coreweave-load-balancer-type" = "public" } : {}
  }
  spec {
    type     = var.public ? "LoadBalancer" : "ClusterIP"
    selector = local.selector
    port {
      name        = "http"
      port        = 80
      target_port = var.port
    }
  }
  wait_for_load_balancer = var.public
}

resource "kubernetes_ingress_v1" "this" {
  count = local.routed ? 1 : 0
  metadata {
    name        = var.name
    namespace   = kubernetes_namespace_v1.this.metadata[0].name
    labels      = local.labels
    annotations = local.routed && try(var.route.tls && var.route.cluster_issuer != "", false) ? { "cert-manager.io/cluster-issuer" = var.route.cluster_issuer } : {}
  }
  spec {
    ingress_class_name = var.route.ingress_class
    rule {
      host = var.route.host
      http {
        path {
          path      = var.route.path_prefix
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.this[0].metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    dynamic "tls" {
      for_each = var.route.tls ? [1] : []
      content {
        hosts       = [var.route.host]
        secret_name = "${var.name}-tls"
      }
    }
  }
}

locals {
  lb_ingress = try(kubernetes_service_v1.this[0].status[0].load_balancer[0].ingress[0], null)
  lb_address = local.lb_ingress == null ? "" : try(coalesce(local.lb_ingress.hostname, local.lb_ingress.ip), "")
  route_url  = local.routed ? "${var.route.tls ? "https" : "http"}://${var.route.host}${var.route.path_prefix == "/" ? "" : var.route.path_prefix}" : ""
  public_url = var.public && local.lb_address != "" ? "http://${local.lb_address}" : ""
}

output "kind" { value = "compute.container-service" }
output "service_id" { value = "${var.name}/${var.name}" }
output "namespace" { value = kubernetes_namespace_v1.this.metadata[0].name }
output "deployment" { value = kubernetes_deployment_v1.this.metadata[0].name }
output "service_name" { value = var.port == null ? "" : var.name }
output "image" { value = var.image }
output "gpu_count" { value = var.gpu == null ? 0 : var.gpu.count }
output "url" { value = local.route_url != "" ? local.route_url : local.public_url }
output "internal_url" { value = var.port == null ? "" : "http://${var.name}.${var.name}.svc.cluster.local" }
