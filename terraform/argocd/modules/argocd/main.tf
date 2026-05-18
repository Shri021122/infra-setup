################################################################################
# Module: argocd
# Deploys the argo/argo-cd Helm chart with a parameterized values file.
#
# Namespace is created here (not via rbac/00-namespace-setup.yaml) so the
# module is self-contained. PSS = baseline (ArgoCD pods don't need privileged).
################################################################################

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/managed-by"        = "terraform"
      "pod-security.kubernetes.io/enforce"  = "baseline"
      "pod-security.kubernetes.io/audit"    = "restricted"
      "pod-security.kubernetes.io/warn"     = "restricted"
      "cluster"                             = var.cluster_name
      "environment"                         = var.environment
    }
  }
}

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = false
  timeout          = 600
  atomic           = true   # Roll back if any resource fails to become ready
  cleanup_on_fail  = true

  values = [
    templatefile("${path.module}/values.yaml.tpl", {
      ha_enabled            = var.ha_enabled
      server_service_type   = var.server_service_type
      server_insecure       = var.server_insecure
      server_cpu_request    = var.server_cpu_request
      server_memory_request = var.server_memory_request
      server_cpu_limit      = var.server_cpu_limit
      server_memory_limit   = var.server_memory_limit
    })
  ]
}
