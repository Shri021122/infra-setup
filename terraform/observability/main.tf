################################################################################
# Observability Stack — Centralized Grafana + Mimir + Loki
#
# IN CLUSTER (this terraform):
#   - Prometheus (agent mode)  → scrapes ServiceMonitors + kube-state-metrics
#                                + kubelet → remote_writes to central Mimir
#   - kube-state-metrics       → Kubernetes object metrics
#
# ON EACH VM (rke2/scripts/install-alloy.sh, not terraform):
#   - Grafana Alloy            → pod logs + journald → central Loki
#                                node + etcd metrics → central Mimir
#
# NOT DEPLOYED:
#   - Alertmanager   (off — central / external)
#   - Grafana        (centralized)
#   - node-exporter  (Alloy does this on the OS)
#   - kube-proxy SM  (Cilium replaces kube-proxy)
################################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubectl" {
  config_path = var.kubeconfig_path
}

module "prometheus_stack" {
  source = "./modules/prometheus"

  namespace       = var.monitoring_namespace
  cluster_name    = var.cluster_name
  environment     = var.environment
  entity          = var.entity
  mimir_tenant_id = var.mimir_tenant_id
  retention_days  = var.prometheus_retention_days
  scrape_interval = var.prometheus_scrape_interval

  central_mimir_url      = var.central_mimir_url
  central_mimir_username = var.central_mimir_username
  central_mimir_password = var.central_mimir_password
}

# ─── Central Grafana Instructions ─────────────────────────────────────────────

output "central_grafana_datasource_instructions" {
  description = "How to query this cluster in your central Grafana"
  value = <<-EOT
    ─── Your central Grafana — query this cluster ─────────────────────────────

    METRICS (Mimir — Kubernetes + cluster components):
      Label filter:    cluster_name = "${var.cluster_name}"
      X-Scope-OrgID:   "${var.mimir_tenant_id != "" ? var.mimir_tenant_id : var.cluster_name}"
      Comes from:      Prometheus (agent mode) remote_write
                       (kube-state-metrics, kubelet, every ServiceMonitor)

    METRICS (Mimir — node + etcd):
      Label filter:    cluster = "${var.cluster_name}"
      Comes from:      Grafana Alloy on each VM (prometheus.exporter.unix + etcd)

    LOGS (Loki — pod logs):
      Stream:          {cluster="${var.cluster_name}", namespace="..."}
      Comes from:      Grafana Alloy reading /var/log/pods/*

    LOGS (Loki — system/RKE2):
      Stream:          {cluster="${var.cluster_name}", job="systemd-journal", unit="rke2-server.service"}
      Comes from:      Grafana Alloy reading journald
    ───────────────────────────────────────────────────────────────────────────
  EOT
}
