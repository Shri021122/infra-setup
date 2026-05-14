################################################################################
# Observability Stack — Centralized Grafana + Mimir + Loki
#
# What runs IN this cluster (Kubernetes):
#   - Prometheus          → scrapes kube-state-metrics, etcd, API server metrics
#                           remote-writes to central Mimir
#   - Alertmanager (×2)  → alert routing (Slack / PagerDuty / email)
#   - kube-state-metrics  → Kubernetes object metrics (deployments, pods, etc.)
#   - (node-exporter DISABLED — Alloy on each VM replaces it)
#
# What runs on each VM (systemd, NOT in Kubernetes):
#   - Grafana Alloy       → pod logs + journald → central Loki
#                           node metrics → central Mimir
#                           etcd metrics (masters only) → central Mimir
#   Installed by: rke2/scripts/install-alloy.sh (called by install-master/worker.sh)
#
# NOT deployed:
#   - Grafana    (centralized)
#   - Loki server (centralized — Alloy pushes directly)
#   - Mimir      (centralized — Prometheus remote-writes to yours)
#   - PMM        (your existing PMM server; no DB pods in this cluster)
#   - Promtail   (replaced by Alloy on the OS)
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

# ─── kube-prometheus-stack ────────────────────────────────────────────────────
# Deploys: Prometheus (HA) + Alertmanager + kube-state-metrics
# node-exporter is DISABLED — Alloy on each VM collects node metrics instead
# Grafana is DISABLED — use your central Grafana

module "prometheus_stack" {
  source = "./modules/prometheus"

  namespace         = var.monitoring_namespace
  cluster_name      = var.cluster_name
  environment       = var.environment
  retention_days    = var.prometheus_retention_days
  storage_size      = var.prometheus_storage_size
  storage_class     = var.prometheus_storage_class
  replicas          = var.prometheus_replicas
  cpu_request       = var.prometheus_cpu_request
  memory_request    = var.prometheus_memory_request
  cpu_limit         = var.prometheus_cpu_limit
  memory_limit      = var.prometheus_memory_limit

  central_mimir_url      = var.central_mimir_url
  central_mimir_username = var.central_mimir_username
  central_mimir_password = var.central_mimir_password
  remote_write_timeout   = var.prometheus_remote_write_timeout
  remote_write_queue_max = var.prometheus_remote_write_queue_max_samples

  alertmanager_slack_webhook = var.alertmanager_slack_webhook
  alertmanager_pagerduty_key = var.alertmanager_pagerduty_key
  alertmanager_email_to      = var.alertmanager_email_to
  alertmanager_smtp_host     = var.alertmanager_smtp_host
}

# ─── Central Grafana Instructions ─────────────────────────────────────────────

output "central_grafana_datasource_instructions" {
  description = "How to query this cluster in your central Grafana"
  value = <<-EOT
    ─── Your central Grafana — query this cluster ─────────────────────────────

    METRICS (Mimir — Kubernetes objects + cluster components):
      Label filter:  cluster = "${var.cluster_name}"
      Comes from:    Prometheus remote-write (kube-state-metrics, etcd, API server)

    METRICS (Mimir — node-level: CPU, RAM, disk, network):
      Label filter:  cluster = "${var.cluster_name}"
      Comes from:    Grafana Alloy on each VM (prometheus.exporter.unix)

    LOGS (Loki — pod logs):
      Stream:  {cluster="${var.cluster_name}", namespace="..."}
      Comes from: Grafana Alloy on each VM reading /var/log/pods/*

    LOGS (Loki — system/RKE2 logs):
      Stream:  {cluster="${var.cluster_name}", job="systemd-journal", unit="rke2-server.service"}
      Comes from: Grafana Alloy reading journald on each VM

    Recommended dashboard imports (filter all by cluster="${var.cluster_name}"):
      7249  — Kubernetes Cluster Overview
      1860  — Node Exporter Full (works with Alloy's prometheus.exporter.unix)
      3070  — etcd
      13639 — Loki Logs
      16611 — Cilium / Hubble
    ───────────────────────────────────────────────────────────────────────────
  EOT
}
