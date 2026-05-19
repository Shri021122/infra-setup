################################################################################
# argocd.tfvars — GitOps control plane for ONE cluster
#
# cluster_name MUST match the other tfvars in this folder.
################################################################################

kubeconfig_path  = "../../clusters/CHANGE_ME/kubeconfig.yaml"
cluster_name     = "CHANGE_ME"
environment      = "production"

argocd_namespace     = "argocd"
argocd_chart_version = "7.7.0"

# ─── Topology ─────────────────────────────────────────────────────────────────
argocd_ha_enabled          = false
argocd_server_service_type = "ClusterIP"
argocd_server_insecure     = true   # set true when argocd_ingress_enabled=true

# ─── Resources ────────────────────────────────────────────────────────────────
argocd_server_cpu_request    = "100m"
argocd_server_memory_request = "256Mi"
argocd_server_cpu_limit      = "500m"
argocd_server_memory_limit   = "512Mi"

# ─── Private Ingress ──────────────────────────────────────────────────────────
argocd_ingress_enabled       = true
argocd_hostname              = "argocd.CHANGE_ME.internal"
argocd_cluster_issuer        = "cluster-ca-issuer"
argocd_lb_ip_pool_cidr       = "10.20.0.200/32"   # /32 = single IP from this CIDR
argocd_lb_l2_interface_regex = "^(eth|ens|enp).*"
