################################################################################
# ArgoCD — top-level variables
################################################################################

variable "kubeconfig_path" {
  description = "Path to kubeconfig for this cluster"
  type        = string
  default     = "../../.secrets/kubeconfig-admin.yaml"
}

variable "cluster_name" {
  description = "Cluster name — used as a label on rendered resources"
  type        = string
  default     = "rke2-prod"
}

variable "environment" {
  description = "Environment label (production, staging, development)"
  type        = string
  default     = "production"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD is installed into. Created by this module."
  type        = string
  default     = "argocd"
}

# ─── Chart ────────────────────────────────────────────────────────────────────

variable "argocd_chart_version" {
  description = <<-EOT
    Pin of the argo/argo-cd Helm chart version.
    Verify against https://github.com/argoproj/argo-helm/releases before bumping.
  EOT
  type        = string
  default     = "8.3.0"
}

# ─── Topology ─────────────────────────────────────────────────────────────────

variable "argocd_ha_enabled" {
  description = <<-EOT
    Enable HA mode: 3 replicas of server/repo-server/applicationset, redis-ha
    instead of single-replica redis. Default false (1 replica each) — fine for
    most clusters; flip to true if ArgoCD is a critical-path service.
  EOT
  type        = bool
  default     = false
}

variable "argocd_server_service_type" {
  description = <<-EOT
    Service type for argocd-server. ClusterIP (default) keeps it private;
    use port-forward or add an Ingress separately. Switch to LoadBalancer
    or NodePort only if you understand the exposure tradeoffs.
  EOT
  type        = string
  default     = "ClusterIP"

  validation {
    condition     = contains(["ClusterIP", "NodePort", "LoadBalancer"], var.argocd_server_service_type)
    error_message = "argocd_server_service_type must be one of: ClusterIP, NodePort, LoadBalancer."
  }
}

variable "argocd_server_insecure" {
  description = <<-EOT
    Run argocd-server with --insecure (HTTP, no TLS on the pod).
    Set true ONLY when a fronting Ingress/Gateway terminates TLS.
    Default false: argocd-server serves its own TLS.
  EOT
  type        = bool
  default     = false
}

# ─── Resources ────────────────────────────────────────────────────────────────

variable "argocd_server_cpu_request" {
  type    = string
  default = "100m"
}

variable "argocd_server_memory_request" {
  type    = string
  default = "256Mi"
}

variable "argocd_server_cpu_limit" {
  type    = string
  default = "500m"
}

variable "argocd_server_memory_limit" {
  type    = string
  default = "512Mi"
}

# ─── Ingress (private, internal-only) ─────────────────────────────────────────

variable "argocd_ingress_enabled" {
  description = <<-EOT
    Create a Cilium Ingress for argocd-server + a cert-manager Certificate.
    When true, you also want argocd_server_insecure=true so the Ingress
    terminates TLS and talks plain HTTP to the backend.
  EOT
  type        = bool
  default     = false
}

variable "argocd_hostname" {
  description = "Internal hostname clients use to reach ArgoCD"
  type        = string
  default     = "argocd.cluster.internal"
}

variable "argocd_cluster_issuer" {
  description = <<-EOT
    cert-manager ClusterIssuer that signs the Ingress cert.
    cluster-ca-issuer = internal CA (no public reachability needed).
    letsencrypt-prod  = real Let's Encrypt cert (requires public HTTP-01 reachability).
  EOT
  type        = string
  default     = "cluster-ca-issuer"
}

variable "argocd_lb_ip_pool_cidr" {
  description = <<-EOT
    CIDR block Cilium L2 Announcements can hand out for LoadBalancer services.
    Default /32 = exactly one IP (10.10.18.200). Expand later by editing the
    CR; no renumbering needed.
  EOT
  type        = string
  default     = "10.10.18.200/32"
}

variable "argocd_lb_l2_interface_regex" {
  description = "Network interface regex Cilium uses to ARP-announce LB IPs"
  type        = string
  default     = "^(eth|ens|enp).*"
}
