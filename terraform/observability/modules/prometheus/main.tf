################################################################################
# Module: prometheus
# Deploys kube-prometheus-stack in agent-only mode (no local TSDB,
# no alertmanager, no in-cluster grafana). All metrics → central Mimir.
################################################################################

terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# The `monitoring` namespace is created in Phase 4 by
# rbac/00-namespace-setup.yaml. Phase 5 only deploys the helm release into it.
data "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
  }
}

locals {
  entity          = var.entity != "" ? var.entity : var.cluster_name
  mimir_tenant_id = var.mimir_tenant_id != "" ? var.mimir_tenant_id : var.cluster_name
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [data.kubernetes_namespace.monitoring]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "80.4.1"
  namespace        = var.namespace
  create_namespace = false
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values.yaml.tpl", {
      cluster_name           = var.cluster_name
      entity                 = local.entity
      mimir_tenant_id        = local.mimir_tenant_id
      retention_days         = var.retention_days
      scrape_interval        = var.scrape_interval
      central_mimir_url      = var.central_mimir_url
      central_mimir_username = var.central_mimir_username
      central_mimir_password = var.central_mimir_password
    })
  ]

  lifecycle {
    prevent_destroy = false
  }
}

# Additional PrometheusRules for infrastructure alerts
resource "kubectl_manifest" "infra_alert_rules" {
  depends_on = [helm_release.kube_prometheus_stack]

  yaml_body = templatefile("${path.module}/alert-rules.yaml.tpl", {
    namespace    = var.namespace
    cluster_name = var.cluster_name
  })
}
