################################################################################
# terraform.tfvars.example — ArgoCD
#
# Copy to terraform.tfvars and adjust for your environment.
################################################################################

kubeconfig_path  = "../../clusters/test-prod/kubeconfig.yaml"
cluster_name     = "test-prod"
environment      = "production"

argocd_namespace     = "argocd"
argocd_chart_version = "7.7.0"   # Check argo-helm releases before bumping

# ─── Topology ─────────────────────────────────────────────────────────────────
# Start with single-replica. Flip ha_enabled=true once ArgoCD is critical.
argocd_ha_enabled          = false
argocd_server_service_type = "ClusterIP"   # Keep private; expose via Ingress later
argocd_server_insecure     = true          # Ingress terminates TLS; pod speaks plain HTTP

# ─── Resources ────────────────────────────────────────────────────────────────
# Defaults are sensible for ~50 Applications. Bump for larger fleets.
argocd_server_cpu_request    = "100m"
argocd_server_memory_request = "256Mi"
argocd_server_cpu_limit      = "500m"
argocd_server_memory_limit   = "512Mi"

# ─── Private Ingress ──────────────────────────────────────────────────────────
# Creates CiliumLoadBalancerIPPool (10.10.18.200/32) + L2AnnouncementPolicy on
# workers, cert-manager Certificate, and an Ingress for argocd.cluster.internal.
# Prereq already satisfied: l2announcements is enabled in the live Cilium config.
# Clients still need: internal DNS argocd.cluster.internal → 10.10.18.200 and
# the cluster CA trusted (same CA as Hubble UI).
argocd_ingress_enabled       = true
argocd_hostname              = "argocd.cluster.internal"
argocd_cluster_issuer        = "cluster-ca-issuer"
argocd_lb_ip_pool_cidr       = "10.10.18.200/32"
argocd_lb_l2_interface_regex = "^(eth|ens|enp).*"
