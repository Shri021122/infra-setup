################################################################################
# Module: argocd — variables
################################################################################

variable "namespace" {
  type = string
}

variable "chart_version" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "ha_enabled" {
  type = bool
}

variable "server_service_type" {
  type = string
}

variable "server_insecure" {
  type = bool
}

variable "server_cpu_request" {
  type = string
}

variable "server_memory_request" {
  type = string
}

variable "server_cpu_limit" {
  type = string
}

variable "server_memory_limit" {
  type = string
}
