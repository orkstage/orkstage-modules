# Logical "ingress" on CKS: a host name under the cluster's ingress domain, served by the ingress
# controller already installed in the cluster (CoreWeave's Traefik chart by default). Each routed
# service attaches itself with an Ingress object for its path in its own namespace; they all
# share this host and the controller merges them. TLS certificates come from cert-manager.

variable "name" { type = string }
variable "host_label" { type = string }
variable "domain" {
  # Empty means <organization id>-<cluster name>.coreweave.app, the wildcard the Traefik chart publishes.
  type    = string
  default = ""
}
variable "cluster_name" {
  type    = string
  default = ""
}
variable "ingress_class" {
  type    = string
  default = "traefik"
}
variable "cluster_issuer" {
  type    = string
  default = "letsencrypt-prod"
}
variable "tls" {
  type    = bool
  default = true
}
variable "routes" { type = string } # JSON object: service resource id to path prefix
variable "labels" {
  type    = map(string)
  default = {}
}

data "coreweave_caller_identity" "current" {}

locals {
  domain = var.domain != "" ? var.domain : "${lower(data.coreweave_caller_identity.current.organization_id)}-${var.cluster_name}.coreweave.app"
  host   = "${var.host_label}.${local.domain}"
}

# Records the edge in the cluster and gives the ingress an owned, deletable resource.
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.name
    labels = merge(var.labels, { "app.kubernetes.io/managed-by" = "orkstage", "orkstage.io/role" = "ingress" })
    annotations = {
      "orkstage.io/host"          = local.host
      "orkstage.io/ingress-class" = var.ingress_class
    }
  }
}

output "kind" { value = "ingress" }
output "namespace" { value = kubernetes_namespace_v1.this.metadata[0].name }
output "host" { value = local.host }
output "url" { value = "${var.tls ? "https" : "http"}://${local.host}" }
output "ingress_class" { value = var.ingress_class }
output "cluster_issuer" { value = var.cluster_issuer }
output "tls" { value = var.tls }
output "routes" { value = var.routes }
