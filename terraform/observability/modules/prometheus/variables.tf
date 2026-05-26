variable "namespace" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "environment" {
  type = string
}
variable "entity" {
  description = "Entity label attached to every metric (defaults to cluster_name when empty)."
  type        = string
  default     = ""
}
variable "mimir_tenant_id" {
  description = "X-Scope-OrgID for central Mimir multi-tenancy (defaults to cluster_name when empty)."
  type        = string
  default     = ""
}
variable "retention_days" {
  description = "Local WAL retention. Agent mode keeps a small buffer for remote_write recovery."
  type        = number
  default     = 3
}
variable "scrape_interval" {
  description = "Default scrape interval (Prometheus + every ServiceMonitor without an override)."
  type        = string
  default     = "30s"
}

# ─── Central Mimir ────────────────────────────────────────────────────────────
variable "central_mimir_url" {
  type = string
}
variable "central_mimir_username" {
  type    = string
  default = ""
}
variable "central_mimir_password" {
  type      = string
  sensitive = true
  default   = ""
}
