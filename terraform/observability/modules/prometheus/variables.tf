variable "namespace" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "environment" {
  type = string
}
variable "replicas" {
  type = number
}
variable "retention_days" {
  type = number
}
variable "storage_size" {
  type = string
}
variable "storage_class" {
  type = string
}
variable "cpu_request" {
  type = string
}
variable "memory_request" {
  type = string
}
variable "cpu_limit" {
  type = string
}
variable "memory_limit" {
  type = string
}
# Centralized Mimir remote-write
variable "central_mimir_url" {
  type = string
}
variable "central_mimir_username" {
  type = string
  default = ""
}
variable "central_mimir_password" {
  type = string
  sensitive = true
  default = ""
}
variable "remote_write_timeout" {
  type = string
  default = "30s"
}
variable "remote_write_queue_max" {
  type = number
  default = 10000
}
# Alertmanager
variable "alertmanager_slack_webhook" {
  type = string
  sensitive = true
  default = ""
}
variable "alertmanager_pagerduty_key" {
  type = string
  sensitive = true
  default = ""
}
variable "alertmanager_email_to" {
  type = string
  default = ""
}
variable "alertmanager_smtp_host" {
  type = string
  default = ""
}