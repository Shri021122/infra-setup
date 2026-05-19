################################################################################
# terraform.tfvars.example — Observability Stack
#
# What Terraform deploys (IN cluster):
#   - Prometheus + Alertmanager + kube-state-metrics
#
# What the install scripts deploy (ON each VM, systemd):
#   - Grafana Alloy  (pod logs + journald + node metrics)
#   Install scripts read central_loki_url / central_mimir_url from this file.
#
# Not deployed (centralized or removed):
#   - Grafana, Loki server, Mimir, PMM, node-exporter, Promtail
################################################################################

kubeconfig_path = "../../clusters/test-prod/kubeconfig.yaml"
cluster_name    = "test-prod"
environment     = "production"

monitoring_namespace = "monitoring"

# ─── Centralized Endpoints (fill these in) ────────────────────────────────────
# Both Prometheus (cluster metrics) and Alloy (node metrics) write to Mimir.
# Alloy (pod logs + journald) pushes to Loki.

central_mimir_url      = "http://mimir.stackflow.org//api/v1/push"
central_mimir_username = ""      # Leave empty if your Mimir has no auth
# export TF_VAR_central_mimir_password=""

central_loki_url       = "http://loki.stackflow.org"
central_loki_username  = ""      # Leave empty if your Loki has no auth
# export TF_VAR_central_loki_password=""

loki_tenant_id         = "test-prod"   # tiefaults to cluster_name if empty

# ─── Prometheus (in-cluster) ──────────────────────────────────────────────────
prometheus_retention_days  = 3       # Short local buffer — Mimir has long-term
prometheus_storage_size    = "20Gi"
prometheus_storage_class   = "local-path"
prometheus_replicas        = 2

prometheus_cpu_request     = "500m"
prometheus_memory_request  = "2Gi"
prometheus_cpu_limit       = "2000m"
prometheus_memory_limit    = "8Gi"

prometheus_remote_write_timeout           = "30s"
prometheus_remote_write_queue_max_samples = 10000

# ─── Alertmanager routing ─────────────────────────────────────────────────────
# export TF_VAR_alertmanager_slack_webhook="https://hooks.slack.com/..."
# export TF_VAR_alertmanager_pagerduty_key="your-pd-key"
alertmanager_email_to   = "devops@yourcompany.com"
alertmanager_smtp_host  = "smtp.yourcompany.com"
