################################################################################
# ArgoCD — GitOps continuous delivery for Kubernetes
#
# What this deploys (IN cluster):
#   - argocd-server                 → UI + API
#   - argocd-application-controller → reconciles Applications against git
#   - argocd-repo-server            → clones + renders source repos
#   - argocd-applicationset-controller → templated app generation
#   - argocd-notifications-controller  → optional alerts
#   - argocd-dex-server             → SSO integration
#   - redis (or redis-ha if ha_enabled)
#
# NOT deployed by this module (kept separate so you can decide independently):
#   - Ingress / Gateway resource    → add cilium ingress in a follow-up apply
#   - cert-manager Certificate      → add once domain is decided
#   - ExternalSecret for admin pw   → optional, see notes in README
#   - AppProject / Application CRs  → GitOps content, not infra
#
# Day-1 access (no Ingress yet):
#   kubectl -n argocd port-forward svc/argocd-server 8080:443
#   open https://localhost:8080
#   admin password:
#     kubectl -n argocd get secret argocd-initial-admin-secret \
#       -o jsonpath='{.data.password}' | base64 -d
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

# ─── ArgoCD ───────────────────────────────────────────────────────────────────

module "argocd" {
  source = "./modules/argocd"

  namespace        = var.argocd_namespace
  chart_version    = var.argocd_chart_version
  cluster_name     = var.cluster_name
  environment      = var.environment

  ha_enabled          = var.argocd_ha_enabled
  server_service_type = var.argocd_server_service_type
  server_insecure     = var.argocd_server_insecure

  server_cpu_request    = var.argocd_server_cpu_request
  server_memory_request = var.argocd_server_memory_request
  server_cpu_limit      = var.argocd_server_cpu_limit
  server_memory_limit   = var.argocd_server_memory_limit
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "argocd_access_instructions" {
  description = "How to log in to ArgoCD on day 1 (before Ingress)"
  value = <<-EOT
    ─── ArgoCD — day-1 access ─────────────────────────────────────────────────

    1) Port-forward the API/UI to your laptop:
       kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:443

    2) Retrieve the initial admin password:
       kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret \
         -o jsonpath='{.data.password}' | base64 -d ; echo

    3) Log in:
       URL:      https://localhost:8080
       Username: admin
       Password: (from step 2)

    4) Change the password from the UI, then DELETE the bootstrap secret:
       kubectl -n ${var.argocd_namespace} delete secret argocd-initial-admin-secret

    Next steps (separate apply):
       - Add a Cilium Ingress + cert-manager Certificate for argocd.<your-domain>
       - Connect repos:  argocd repo add <git-url>
       - Create AppProjects and Applications via git
    ───────────────────────────────────────────────────────────────────────────
  EOT
}

output "argocd_namespace" {
  description = "Namespace ArgoCD is deployed into"
  value       = var.argocd_namespace
}
