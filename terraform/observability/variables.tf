################################################################################
# Observability Stack Variables
#
# IN CLUSTER  → Prometheus (agent mode) — scrapes ServiceMonitors + kubelet
#               + kube-state-metrics, remote_writes everything to central Mimir.
# ON EACH VM  → Grafana Alloy (systemd) — pod logs, journald, node + etcd metrics.
# CENTRALIZED → Grafana + Mimir + Loki (not deployed here).
# REMOVED     → Alertmanager, in-cluster Grafana, node-exporter, kube-proxy SM.
################################################################################

variable "kubeconfig_path" {
  description = "Path to kubeconfig for this cluster"
  type        = string
  default     = "../../.secrets/kubeconfig-admin.yaml"
}
variable "cluster_name" {
  description = "Cluster name — attached as label to all metrics and logs"
  type        = string
}
variable "environment" {
  description = "Environment label (production, staging, development)"
  type        = string
  default     = "production"
}
variable "entity" {
  description = "Entity/tenant identifier. Defaults to cluster_name when empty."
  type        = string
  default     = ""
}
variable "monitoring_namespace" {
  description = "Namespace for Prometheus"
  type        = string
  default     = "monitoring"
}

# ─── Prometheus ───────────────────────────────────────────────────────────────

variable "prometheus_retention_days" {
  description = "WAL retention buffer (agent mode keeps a small buffer for remote_write recovery)"
  type        = number
  default     = 3
}
variable "prometheus_scrape_interval" {
  description = "Default Prometheus scrape interval"
  type        = string
  default     = "30s"
}

# ─── Centralized Mimir ────────────────────────────────────────────────────────

variable "central_mimir_url" {
  description = "Central Mimir remote-write URL"
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
variable "mimir_tenant_id" {
  description = "X-Scope-OrgID for Mimir multi-tenancy. Defaults to cluster_name when empty."
  type        = string
  default     = ""
}

# ─── Centralized Loki (consumed by Alloy on each VM, not in-cluster) ──────────

variable "central_loki_url" {
  description = "Central Loki push base URL (no path — Alloy adds /loki/api/v1/push)"
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
