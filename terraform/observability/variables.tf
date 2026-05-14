################################################################################
# Observability Stack Variables
#
# Architecture:
#   IN CLUSTER  → Prometheus (kube-state-metrics, etcd, API server metrics)
#                 Alertmanager
#   ON EACH VM  → Grafana Alloy (pod logs, journald, node metrics)
#   CENTRALIZED → Grafana + Mimir + Loki  (yours — not deployed here)
#   REMOVED     → Promtail (replaced by Alloy), PMM (your existing server),
#                 node-exporter (replaced by Alloy), Loki server, Mimir server
################################################################################

variable "kubeconfig_path" {
  description = "Path to kubeconfig for this cluster"
  type        = string
  default     = "../../.secrets/kubeconfig-admin.yaml"
}
variable "cluster_name" {
  description = "Cluster name — attached as label to all metrics and logs"
  type        = string
  default     = "rke2-prod"
}
variable "environment" {
  description = "Environment label (production, staging, development)"
  type        = string
  default     = "production"
}
variable "monitoring_namespace" {
  description = "Namespace for Prometheus and Alertmanager"
  type        = string
  default     = "monitoring"
}
# ─── Prometheus ───────────────────────────────────────────────────────────────

variable "prometheus_retention_days" {
  description = "Local retention (short — Mimir holds long-term)"
  type        = number
  default     = 3
}
variable "prometheus_storage_size" {
  description = "PVC size for Prometheus local buffer"
  type        = string
  default     = "20Gi"
}
variable "prometheus_storage_class" {
  description = "StorageClass for Prometheus PVC"
  type        = string
  default     = "local-path"
}
variable "prometheus_replicas" {
  description = "Prometheus replicas (2 = HA)"
  type        = number
  default     = 2
}
variable "prometheus_cpu_request" {
  type = string
  default = "500m"
}
variable "prometheus_memory_request" {
  type = string
  default = "2Gi"
}
variable "prometheus_cpu_limit" {
  type = string
  default = "2000m"
}
variable "prometheus_memory_limit" {
  type = string
  default = "8Gi"
}
variable "prometheus_remote_write_timeout" {
  type    = string
  default = "30s"
}
variable "prometheus_remote_write_queue_max_samples" {
  type    = number
  default = 10000
}
# ─── Centralized Mimir ────────────────────────────────────────────────────────

variable "central_mimir_url" {
  description = "Your centralized Mimir remote-write URL"
  type        = string
}
variable "central_mimir_username" {
  description = "Mimir basic-auth username (leave empty if no auth)"
  type        = string
  default     = ""
}
variable "central_mimir_password" {
  description = "Mimir basic-auth password — set via TF_VAR_central_mimir_password"
  type        = string
  sensitive   = true
  default     = ""
}
# ─── Centralized Loki ─────────────────────────────────────────────────────────
# Used only by Alloy (configured in rke2/configs/alloy-config.alloy.tpl).
# Terraform reads these so deploy.sh can pass them to install-alloy.sh.

variable "central_loki_url" {
  description = "Your centralized Loki push base URL (no path — Alloy adds /loki/api/v1/push)"
  type        = string
}
variable "central_loki_username" {
  description = "Loki basic-auth username (leave empty if no auth)"
  type        = string
  default     = ""
}
variable "central_loki_password" {
  description = "Loki basic-auth password — set via TF_VAR_central_loki_password"
  type        = string
  sensitive   = true
  default     = ""
}
variable "loki_tenant_id" {
  description = "Loki tenant/org ID — defaults to cluster_name if empty"
  type        = string
  default     = ""
}
# ─── Alertmanager ─────────────────────────────────────────────────────────────

variable "alertmanager_slack_webhook" {
  type      = string
  sensitive = true
  default   = ""
}
variable "alertmanager_pagerduty_key" {
  type      = string
  sensitive = true
  default   = ""
}
variable "alertmanager_email_to" {
  type = string
  default = ""
}
variable "alertmanager_smtp_host" {
  type = string
  default = ""
}