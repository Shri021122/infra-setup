################################################################################
# Module: prometheus
# Deploys kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# via Helm with production-grade configuration.
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
# rbac/00-namespace-setup.yaml (with the same `privileged` PSS labels
# Prometheus needs for host-level access). Phase 5 only deploys the
# Helm release into it.
data "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [data.kubernetes_namespace.monitoring]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "80.4.1"    # Pin version; test upgrades in staging first
  namespace        = var.namespace
  create_namespace = false
  timeout          = 600
  atomic           = true    # Roll back on failure
  cleanup_on_fail  = true

  # Merge all values into a single YAML string
  values = [
    templatefile("${path.module}/values.yaml.tpl", {
      cluster_name           = var.cluster_name
      environment            = var.environment
      replicas               = var.replicas
      retention_days         = var.retention_days
      storage_size           = var.storage_size
      storage_class          = var.storage_class
      cpu_request            = var.cpu_request
      memory_request         = var.memory_request
      cpu_limit              = var.cpu_limit
      memory_limit           = var.memory_limit
      central_mimir_url      = var.central_mimir_url
      central_mimir_username = var.central_mimir_username
      central_mimir_password = var.central_mimir_password
      remote_write_timeout   = var.remote_write_timeout
      remote_write_queue_max = var.remote_write_queue_max
      slack_webhook          = var.alertmanager_slack_webhook
      pagerduty_key          = var.alertmanager_pagerduty_key
      email_to               = var.alertmanager_email_to
      smtp_host              = var.alertmanager_smtp_host
    })
  ]

  lifecycle {
    # Prevent Helm from removing CRDs on destroy (they contain alert rules)
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
