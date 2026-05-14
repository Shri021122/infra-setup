################################################################################
# Module: prometheus
# Deploys kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
# via Helm with production-grade configuration.
################################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce"         = "privileged"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "app.kubernetes.io/managed-by"               = "terraform"
    }
  }
}

resource "helm_release" "kube_prometheus_stack" {
  depends_on = [kubernetes_namespace.monitoring]

  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "58.2.2"    # Pin version; test upgrades in staging first
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
      grafana_admin_password = var.grafana_admin_password
      grafana_domain         = var.grafana_domain
      grafana_storage_size   = var.grafana_storage_size
      grafana_replicas       = var.grafana_replicas
      mimir_enabled          = var.mimir_enabled
      external_prometheus_url = var.external_prometheus_url
      slack_webhook          = var.alertmanager_slack_webhook
      pagerduty_key          = var.alertmanager_pagerduty_key
      email_to               = var.alertmanager_email_to
      smtp_host              = var.alertmanager_smtp_host
      ingress_class          = var.ingress_class
      tls_cluster_issuer     = var.tls_cluster_issuer
      oidc_enabled           = var.oidc_enabled
      oidc_client_id         = var.oidc_client_id
      oidc_client_secret     = var.oidc_client_secret
      oidc_auth_url          = var.oidc_auth_url
      oidc_token_url         = var.oidc_token_url
      namespace              = var.namespace
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
